---
title: 'Epic-21 backend hardening — portal controller scan, replay under the lock, status pin, dead-helper removal, and the two pinned tests'
type: 'chore'
created: '2026-10-11'
status: 'done'
route: 'dispatch'
baseline_commit: '592f70373d5cd6787806f01408de47587eb868a8'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-21-context.md'
  - '_bmad-output/implementation-artifacts/epic-21-retro-2026-10-10.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/billing.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The epic-21 retro left backend items open:
- **(X3)** Nothing ties `portal.controller.ts`'s calls to the client-stamped allowlists, so a new portal route calling an unstamped facade read would leak every client's rows and pass every test.
- **(B2)** Several lock-taking commands skip the second idempotency replay under the lock, so a concurrent same-key duplicate fails on the key's unique index instead of replaying.
- **(B6)** `CLIENT_STATUSES` has no TS-tuple ↔ CHECK pin.
- **(S2)** Two of the epic's "tests to pin" are only partial:
  - an HTTP cross-client wave;
  - CAP-5 (a deleted draft re-prepares identically).
- **(21-10 deferral)** `getClientStatusInTx` is now unused, and a stray future use would reopen the suspension race.

**Approach:** No behaviour change for any caller:
- the scan and pin tests;
- the missing replay step;
- deleting the dead helper;
- the two pinned end-to-end tests.

**Decisions (human, 2026-10-11):**
1. **Split by repo.** 21-11 became 21-11a (this backend story) and 21-11b (frontend: charge labels, the warehouse failed-read state, portal decoupling).

## Boundaries & Constraints

**Always:**
- **(X3) The portal controller scan** goes in `test/architecture.spec.ts`, beside the `PORTAL_READS` block at `:1743-1830`.
  - **Field map:** read `src/api/portal.controller.ts`'s constructor (`@Inject(X) private readonly <field>`) into a field → facade-class map. Assert it equals the expected map:
    - clients → ClientsFacade;
    - inventory → InventoryFacade;
    - outbound → OutboundFacade;
    - inbound → InboundFacade;
    - billing → BillingFacade;
    - catalog → CatalogFacade;
    - tenancy → TenancyService;
    - reporting → ReportingFacade.
  - **Call set:** extract every call with `/this\.(\w+)\s*\??\.\s*(\w+)\s*\(/g`, which also catches multi-line and optional calls. Compare **`field.method` pairs**: the allowed pairs map each `PORTAL_READS` file → facade class → controller field, plus the **declared delegations** `{clients.portalMe → portalMeIn, inbound.announceAsn → announce}`.
  - **No escape hatches:** every `this.<field>` occurrence must be immediately followed by `.method(`. That catches an alias (`const o = this.outbound`), a destructure, and passing a facade as a bare argument.
  - **Delegations:** each target must be in `PORTAL_READS` / `PORTAL_WRITES`, and each delegating facade method's body is asserted to be **a single `return <target>(…);` statement**, so an extra unstamped call cannot hide inside it.
  - **A detector test** proves the scan flags each of these in fixture strings: an unknown call (`this.outbound.listOrders(`), a multi-line call, and an alias.
- **(B2) Replay under the lock.** Add `const replayedUnderLock = await this.replay(…); if (replayedUnderLock !== null) return replayedUnderLock;` after the row lock(s) and before any state check. The pattern is `clients.command.ts` `updateTaxDetails` `:325-328`. Per command:
  - **`AsnCommand.amend`:** replay `asn.command.ts:674`, `lockAsn` `:680`, which only locks. Pre-fix, the duplicate fails on the key's unique index (409 `conflict`).
  - **`AsnCommand.transition`:** `:795` / `:800`. Pre-fix, the duplicate fails 409 `asn-transition-invalid`, since the state already moved.
  - **`PoCommand.amend` and `close`** (`po.command.ts:329,487`):
    - `loadOpenPo` (`:684-700`) locks **and** refuses a non-open PO, so a replay placed after it is unreachable for `close`.
    - **Split it** into `lockPo` (lock + 404) and `assertPoOpen`, and put the second replay between them in both commands. Every other caller of `loadOpenPo` calls the two in sequence, with unchanged behaviour.
    - Pre-fix: `close` fails 409 `po-not-open`; `amend` fails 409 `conflict`.
  - **`SkuClientCommand.correct`:** `sku-client.command.ts` has no `replay` method (the replay is inlined at `:124-134`). **Extract** it into a private `replay(tx, tenantId, key, hash)` and call it at both sites; the second goes after the **last** lock (`:166`). The 404 at `:146` comes before both locks. Pre-fix, the duplicate takes the no-op arm (`:183-185`) and returns `{skus:[target]}`, which differs from the winner's body **only for a group of ≥ 2 SKUs**, so the race uses a kit or product group of at least 2.
  - **`ClientsCommand.rename`:** `clients.command.ts:240` / `:251-256`. Add the replay for consistency, but **no mutation-checked race**: the duplicate takes the no-op arm (`:268-270`) and already returns an identical body with no second effect. Record this in Design Notes.
  - **Tests:** one deterministic same-key race per command except rename.
    - A raw holder locks the row `FOR UPDATE`; two same-key requests park behind it; then release.
    - Each spec gets a local `waitParked(table, n)` (from `clients.spec.ts:1368-1398`, 21-10) with the table **parameterised**: `advance_shipment_notices`, `purchase_orders`, and `products` for the SKU group, which is locked first (`sku-client.command.ts:155-160`).
    - **Assert:** both return the same status and an identical body, with exactly one effect and one `idempotency_keys` row.
    - Each test fails with the replay removed, with the pre-fix error named above.
- **(B6) Status pin.** In `test/client-dimension.spec.ts`, beside `:338`, read `pg_get_constraintdef` of `clients_status_check`, extract the `'…'` arms, and assert they equal `[...CLIENT_STATUSES].sort()`. The pattern is `rate-cards.spec.ts:378-392`.
- **Delete `getClientStatusInTx`** (`clients.facade.ts:209`; no callers in `src` or `test`). Update:
  - `docs/design/modules/clients.md:40,41,132` (it is removed);
  - the stale `inbound.md:302` (announce uses `shareLockClientInTx`).
- **(S2a) HTTP cross-client wave**, in `test/clients.spec.ts`, reusing its device and flow setup (`:363-420`, flow `:961-1011`):
  1. ACME and BETA, each with a SKU and stock;
  2. one order per client;
  3. **one** wave over both orders with a `batch` policy (one picklist holding both clients' lines);
  4. release; pick every line on the device; pack and dispatch both orders.
  - **Assert:**
    - the wave produced **one** picklist holding lines of both orders (as in `waves.spec.ts:678-692`);
    - both orders `dispatched`;
    - the `pick.picked` events for each order (linked through `reference_doc.orderId`) carry that order's client, which is where the shared picklist could mis-attribute;
    - a portal user of each client (the `portalUser` pattern, `portal.spec.ts:356-373`) sees exactly its own order in `portal/orders` and gets 404 for the other's id.
- **(S2b) CAP-5 recompute**, in `test/client-invoices.spec.ts`, using the helpers `prepare` `:813`, `act` `:817`, `getInvoice` `:821`, `contentHash` `:834`:
  1. prepare a month's draft;
  2. record its `content_hash`, totals, and lines without `id`;
  3. `DELETE …/client-invoices/:id` (discard);
  4. prepare the same month again.
  - The re-prepare uses a **fresh** idempotency key, so it cannot pass by replaying the deleted draft's snapshot.
  - **Assert:** the new invoice id differs from the old one; the `content_hash` re-read from the new row, the totals and the id-stripped lines are deep-equal. `clientInvoiceContentHash` (`client-invoices.ts:545-578`) excludes ids, the number, timestamps and status.
- **X4 is already fixed by 21-9** (`receiving.controller.ts:91`). No change; the retro item records it as done.

**Never:**
- changing any command's observable behaviour beyond replaying a concurrent same-key duplicate;
- a shared test-helper module (per-spec helpers are the convention);
- any FE change (that is 21-11b);
- a migration.

## I/O & Edge-Case Matrix

| Scenario | State | Expected | Error |
|---|---|---|---|
| Unstamped portal call | A controller calls a facade method not in the allowlist | The architecture test fails | — |
| New controller field | A field not in the expected map | The architecture test fails | — |
| Same-key race | Two identical requests parked behind a row lock | Both return the same body; one effect; one key row | — |
| Status drift | The `CLIENT_STATUSES` tuple ≠ the CHECK arms | The pin test fails | — |
| Cross-client wave | One batch wave, two clients | Both dispatched; each portal sees only its own | Foreign id → 404 |
| CAP-5 | Discard, then re-prepare the same month | Identical hash, totals and lines | — |

</frozen-after-approval>

## Code Map

Paths are relative to `workspace/core/backend/wms-be`.

- **Architecture test:** `test/architecture.spec.ts:1743-1830` (`PORTAL_READS`, `bodyOf`, `stampsClient`, `PORTAL_WRITES`, `stampsCommandClient`).
- **Portal controller:** `src/api/portal.controller.ts:88-96` (fields), with calls at `:109,130,149,174,194,244,280,300,325,347,367,402,425,448`.
- **Delegations:** `clients.facade.ts:92` → `portalMeIn` `:379`; `inbound.facade.ts:210` → `AsnCommand.announce`.
- **Commands:**
  - `src/modules/inbound/asn.command.ts:674-680,795-800`;
  - `src/modules/clients/clients.command.ts:240-256,325-328`;
  - `src/modules/catalog/sku-client.command.ts:124-166`;
  - `src/modules/inbound/po.command.ts:329,487,688`.
- **Pin:** `src/shared/db/schema.ts:137`; `drizzle/0040_client_dimension.sql:96-98`; `test/client-dimension.spec.ts:338-353`; the pattern `test/rate-cards.spec.ts:378-392`.
- **Dead helper:** `src/modules/clients/clients.facade.ts:209`.
- **Wave and portal helpers:** `test/clients.spec.ts:239-420,961-1011` (and `waitParked` from 21-10); `test/portal.spec.ts:250-373,840-857`; `src/modules/outbound/outbound.dto.ts:399` (`batch`).
- **Invoices:** `src/api/client-invoices.controller.ts:135,292,320`; `src/modules/billing/client-invoices.ts:545,1071`; `test/client-invoices.spec.ts:813-834,1137,1308-1312`.

## Tasks & Acceptance

**Execution:**
- [x] `test/architecture.spec.ts` -- the controller scan + detector -- X3.
- [x] The five command files -- replay under the lock -- B2; plus one same-key race per command in its spec.
- [x] `test/client-dimension.spec.ts` -- the status pin -- B6.
- [x] `clients.facade.ts` -- delete `getClientStatusInTx` -- the 21-10 deferral.
- [x] `test/clients.spec.ts` -- the HTTP cross-client wave -- S2a.
- [x] `test/client-invoices.spec.ts` -- discard → re-prepare identical -- S2b.
- [x] Meta docs:
  - `clients.md:40,41,132`;
  - `inbound.md:302`;
  - IMPLEMENTATION-GUIDE §1: a lock helper must **not** also check status (the `loadOpenPo` lesson), or the replay under the lock is unreachable; cite the race-test pattern;
  - PENDING: the lock-taking commands not audited here (putaway, pick, transfer, count, replenishment, import, sku) — each needs the same check;
  - `deferred-work.md` (close the 21-10 `getClientStatusInTx` entry).

**Acceptance Criteria:**
- Given each new test, when its target fix or guard is removed, then that test fails (mutation-checked).
- Given the full BE suite, lint and typecheck, when run, then they pass.

## Implementation Notes

Baseline: wms-be `592f70373d5cd6787806f01408de47587eb868a8` (`baseline_commit`). Backend only.
- Work on `feat/21-11a-epic-21-be-hardening` in wms-be (already checked out). Leave everything uncommitted: no commit, push or PR.
- Run `bun run test -- <file>`; never bare `bun test`, and never two jest invocations at once (globalSetup sweeps kill the other run's DBs). The ledger idempotency-race test can flake under full-suite load only; rerun it alone before blaming the story.
- Real Postgres and Valkey must be up for the suites (wms-be docker-compose).
- Edit meta docs in `/Users/sasidhar/Documents/WMS-Meta` (uncommitted, on the current branch).
- Do not touch wms-fe or wms-mobile.

## Spec Change Log

## Review Triage Log

Design review (2026-10-11), one lens: claims, coverage and testability.

| # | Finding | Verdict | Disposition |
|---|---|---|---|
| 1 | `loadOpenPo` locks and refuses a non-open PO in one step, so a replay after it is unreachable for `close` | high — verified, `po.command.ts:684-700` | Fixed: split into `lockPo` / `assertPoOpen` |
| 2 | Rename's race test cannot fail: the no-op arm already returns the identical body | high — verified, `clients.command.ts:268-270` | Fixed: replay kept; mutation check exempted |
| 3 | The SKU-correction race fails only for a ≥2-SKU group; there is no `replay` method | medium | Fixed: extract `replay`; ≥2-SKU group |
| 4 | "Every lock-taking command" was asserted without an audit | medium | Fixed: scope narrowed to six; PENDING lists the rest; guide lesson |
| 5 | The scan regex misses multi-line, optional and alias calls | medium | Fixed: regex, no-escape assertion, detector fixtures |
| 6 | The scan compared method names, not field-and-method pairs | low | Fixed |
| 7 | The delegation check allowed extra calls | low | Fixed: a single `return` statement |
| 8 | `waitParked` is hard-wired to `clients`; the pre-fix failure differs per command | medium | Fixed: table parameter; named per command |
| 9 | The CAP-5 test could pass by replaying | medium | Fixed: a fresh key; a new id; hash re-read |
| 10 | The cross-client wave asserted dispatch only; the risk is the shared picklist | low | Fixed: one-picklist and `pick.picked` attribution asserts |
| 11 | The B6 regex and `conname` filter are sound | — | No change |
| 12 | The docs list is complete; the PENDING line for unaudited commands was missing | low | Fixed |

**Code review (2026-10-12)** — Blind Hunter (B), Edge Case Hunter (E), Verification Gap (V); 29 raw findings, 25 distinct.

| # | Layer | Finding | Verdict | Route |
|---|---|---|---|---|
| C1 | V, B | The scan reads only `portal.controller.ts`; a portal route in another controller bypasses it | medium — verified, `architecture.spec.ts` `PORTAL_CONTROLLER` | patch: pin `PortalSessionGuard` users to that file |
| C2 | E | An allowed portal read could receive a client id from the query or body | medium | patch: every call passes `session.clientId`; detector |
| C3 | B, E | The delegation check accepts extra work inside its arguments | low | patch: pin the exact delegation text |
| C4 | E | A `PORTAL_READS` file missing from the class map yields `undefined` pairs silently | low | patch: throw |
| C5 | B | ASN `close` has no race test (a different path from cancel) | medium | patch |
| C6 | B | The wave test does not count pick events, and sits under the 21-10 banner | low | patch |
| C7 | B | The status pin looks the constraint up by name only | low | patch: `conrelid` |
| C8 | B | The CAP-5 test regenerates the draft that the later `stale` test uses | low | patch: state or remove the dependency |
| C9 | B, E | Docs: `clients.md` says create locks; the command class comment is stale; `catalog.md` misses the SKU-correction replay; the `inbound.md` ASN intro and PO anchors are stale; the guide says `PoCommand` | low | patch: docs |
| C10 | V, B, E | The PENDING unaudited list is incomplete and reads as exhaustive; same-key concurrent creates are a separate class | low | patch: non-exhaustive, extended, create class noted |
| C11 | E | Same-key concurrent creates (ASN create/announce, PO create) answer 409 instead of replaying | medium — real; pre-existing, a different class from B2 | defer (PENDING via C10) |
| C12 | B | The race helpers are copied into three spec files | low — the spec chose per-spec helpers (the repo convention) | reject |
| C13 | B, E | `codeOnly` does not handle regex literals | low — the controller has none; the fix needs a parser | reject |
| C14 | B | The wave test does not check billing metering rows | low — outside this pin's intent (CAP-2 and attribution) | reject |

## Design Notes

- **Why a field map plus a call set, not only a call set.** A new facade field could bring in a whole facade whose methods share names with stamped ones. Pinning the field → class map closes that.
- **Why include the PO and SKU-correction commands.** They are the same defect class the retro named (B2), found in the same pass. The scope is these six; the rest go to PENDING rather than being claimed as covered.
- **Why rename has no race test.** Its no-op arm already gives the duplicate the winner's body with no second effect, so a mutation check could not fail. The replay is added only for consistency with the skeleton.
- **Why compare `content_hash`.** It already covers rate card, segments, charge, basis, UoM, quantity, unit, amount, SAC and tax (`client-invoices.ts:545`). Line ids differ on every write, so they are stripped.
