---
title: '1-6c drug and FSSAI licences — client and site licences, coverage gaps, expiry warnings'
type: 'feature'
created: '2026-10-20'
status: 'done'
baseline_commit: 'f5f0c3a2f5a1b15b179ad9a8481b6c96cd46244f'  # wms-be; wms-fe: 733fc17af1796604c7a27b4204f416c53130aa1e; wms-mobile: f81fd3adc208dc4f472c1738d5e7ff0f140e9f28
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/compliance.md'
  - 'docs/design/modules/clients.md'
  - 'docs/design/modules/notifications.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The warehouse holds scheduled drugs and food (D8), and 1-6a records which SKUs are which. But nothing records the Drugs & Cosmetics Act or FSSAI licences that make holding them legal. Nobody can see that a brand's Schedule X goods at the Pune site have no Form 20G behind them, or that a site's FSSAI licence lapses next month.

**Approach:**
- Record each statutory licence on its holder: a **client** (the brand), optionally for one site, or a **warehouse** (the 3PL's site).
- Show the **coverage gaps** wherever drug or food goods actually are.
- **Warn** from 60 days before expiry.

Blocking uncovered work is story 1-6d (deferred-work), built on this one.

**Decisions (user, 2026-10-20):**
1. **Licence kinds are statutory forms.** A SKU has one need per schedule it carries; an `H` + `NDPS` SKU needs both `drug-20b` and `ndps`.

   | Need | Covered by kind | For |
   |---|---|---|
   | `drug-20b` | `drug-20b` | Drug schedules `G`, `H`, `H1` |
   | `drug-21b` | `drug-21b` | Drug schedules `C`, `C1` |
   | `drug-20g` | `drug-20g` | Drug schedule `X` |
   | `ndps` | `ndps` | Drug schedule `NDPS` |
   | `fssai` | `fssai-registration`, `fssai-state`, `fssai-central` | Food (1-6b `isFood`); any tier covers |

2. **Both holders, where the goods are.** Coverage is judged per **(client C, site W)** pair. A pair is counted when C has drug or food stock on hand at W, or such a SKU on an open PO or ASN into W. Each need of those SKUs requires both of these, valid on IST today:
   - a **client licence** of a covering kind, held by C, that is either for W or names no site (a head-office or central licence);
   - a **site licence** of a covering kind, held by W.

   A client with no such goods anywhere has no gap.
3. **Warnings from 60 days, fixed.**
   - `upcoming` when `addIsoDays(validUntil, −60) ≤ today ≤ validUntil`.
   - `expired` when `today > validUntil`.
   - Each fires once per term (IST dates).
4. **The `self` client is covered by the site licence.** Your own company's goods need only site coverage. `self` never shows a client gap, and it cannot hold a licence (400).

**Decisions (agent):**
5. **One table, owned by compliance: `licences`.**
   - **Columns:**
     - `client_id` (nullable);
     - `warehouse_id` (nullable: the site of a site licence, or the premises of a client licence);
     - `kind`, `number`, `valid_from`, `valid_until`, `note`;
     - `status` `active | withdrawn`;
     - `upcoming_warned_on`, `expired_warned_on` and `open_warning_id` (the sweep's state).
   - **Holder:** a client licence when `client_id` is set, else a site licence, which needs `warehouse_id`.
   - **Lifecycle:** a licence is never deleted, only withdrawn. Kind, client and site are fixed; a correction is a withdraw plus a new add.
6. **Validity and expiry.**
   - **Valid on date D:** `active`, `valid_from` is null or ≤ D, and `valid_until` is null or ≥ D.
   - **Which kinds need `validUntil`:** `fssai-*` and `ndps`. A drug form's `validUntil` is optional and is labelled "Valid until / retention due"; perpetual licences pay a retention fee every five years. A licence without it never warns.
7. **Numbers.**
   - **Normalisation:** trimmed, with spaces collapsed, then upper-cased.
   - **FSSAI:** 14 digits. A registration starts with `2`; a state or central licence starts with `1`.
   - **Drug and NDPS:** 1–50 characters of `A–Z 0–9 space / . -`.
   - **Uniqueness:** a number is unique among a tenant's active licences within its family. All three FSSAI tiers form one family; each drug kind is its own family. A clash on add or edit is 409 `licence-number-taken`.
8. **Warnings as notifications.**
   - Each raise mints a fresh `warningId`, which is the notification's `sourceId`, and stores it in `open_warning_id`.
   - Outbox `licence.expiry_upcoming` or `licence.expired` opens an entry. `licence.expiry_warning_cleared` resolves it, with outcome:
     - `renewed`: an edit moved `validUntil` out of the warned state;
     - `withdrawn`;
     - `expired`: the expired raise closes the open upcoming entry.
   - Audience: `licences.manage`. Never pushed; no email.
9. **The sweep does not warn when:**
   - the licence is withdrawn;
   - it belongs to a departed client;
   - its `validUntil` is before the IST date it was added (a historical record);
   - a successor covers the gap: an active licence with the same client, site and need that is valid on `validUntil + 1`.
10. **Edits.**
    - `validFrom`, `validUntil` and `note` are absent = keep, null = clear. `number` cannot be null.
    - Rules are checked against the merged row. Clearing `validUntil` on an FSSAI or NDPS licence is 400.
    - When `validUntil` changes and the warning state it implies differs from the warned state, the open warning clears (`renewed`) and both warned dates reset.
    - An unchanged edit writes nothing and stores its key. Editing or withdrawing a withdrawn licence is 409 `licence-withdrawn`.
11. **Access.**
    - New capability `licences.manage`, owner-only, for writes.
    - Reads are open to any staff session; a portal session gets 403 `role-denied`.
    - Errors: an unknown client, warehouse or licence is 404 `not-found`. A departed client cannot gain a licence (409 `client-departed`).

## Boundaries & Constraints

**Always:**
- **Migration 0084** (the 0082/0083 shape: fail-fast, DDL, CHECKs, a `DO $$` probe refusing each CHECK by name):
  - **`licences` CHECKs:**
    - the kind vocabulary;
    - the holder rule (`client_id` or `warehouse_id` set);
    - FSSAI 14 digits with the `1`/`2` prefix per kind;
    - the drug number pattern;
    - `valid_until ≥ valid_from`;
    - `valid_until` required for `fssai-*` and `ndps`;
    - status;
    - note ≤ 200.
  - **Indexes:**
    - the family unique `(tenant_id, CASE WHEN kind LIKE 'fssai-%' THEN 'fssai' ELSE kind END, number) WHERE status = 'active'`;
    - `(tenant_id, client_id)` and `(tenant_id, warehouse_id)`.
  - **RLS** in the 0077 shape, with the client arm on `client_id`. The probe proves a site row (null `client_id`) is invisible, and its insert refused, under a stamped `app.client_id`.
  - **`notifications_source_type_check`** widened with `licence-expiry` (drop and re-add).

  Commit the snapshot and journal entry; `db:generate` must report no changes.
- **Primitive `src/shared/primitives/licence.ts`:**
  - `LICENCE_KINDS`, `LICENCE_NEEDS`, `NEED_COVERED_BY`;
  - `normalizeLicenceNumber`, `licenceNumberProblem(kind, number)`;
  - `needsOf(profile)` (1-6b `isFood`, `drugSchedules`);
  - `licenceValidOn`;
  - `clientLicenceCovers(licence, clientId, warehouseId, need, date)` and `siteLicenceCovers(…)`;
  - `warningState(validUntil, istToday)`, using `addIsoDays` only.

  Unit tests cover every schedule, multi-schedule SKUs, every boundary (day 61, day 60, the expiry day, the day after), the number rules and the coverage predicates.
- **Compliance module, which reads other modules' tables without importing their modules** (the `excursion.command.ts:20` precedent; no new module import):
  - **`LicenceCommand`** (`add`, `edit`, `withdraw`) follows the keyed-command skeleton:
    - hash arms `licence-add | licence-edit | licence-withdraw` over the tenant and the normalized fields;
    - `licences.manage`;
    - replay, then holder existence through `assertClientInTenantInTx` / `assertWarehouseInTenant`;
    - lock, then replay again under the lock;
    - shape checks on the merged row;
    - the write, catching the index with `isUniqueViolationOn`;
    - audit `licence.added | licence.edited | licence.withdrawn` with target type `licence` (`AUDIT_TARGET_TYPES`), the unchanged-edit arm going in `AUDIT_NO_OP_ARMS`;
    - key last.
  - **`LicenceFacade`:**
    - `listLicences(tenantId, filters, istToday?)` → `{asOfDate, items[]}`, each with `expiryState: 'valid' | 'upcoming' | 'expired' | 'withdrawn'` and `daysLeft`;
    - `coverageGaps(tenantId, istToday?)` → `{asOfDate, gaps: {holder: 'client' | 'site', clientId?, warehouseId, need, coveredBy[], skuCount}[]}`. It is computed in SQL over drug/food stock on hand (`quantity > 0`) and open PO/ASN lines, excluding departed clients, and treats `self` per decision 4.
    - `sweepExpiry(tenantId, istToday)` opens its own tenant transaction. It locks due rows ordered by id with `FOR NO KEY UPDATE SKIP LOCKED`, applies decision 9, raises each warning (outbox plus one audit row: `licence.expiry_upcoming_raised` / `licence.expired_raised`, system actor), and, when an expired raise supersedes an upcoming one, emits a clear first.
    - `ComplianceModule` exports the facade.
- **Routes** (`src/api/licences.controller.ts`):
  - `GET/POST …/licences`, `PATCH …/licences/{id}`, `POST …/licences/{id}/withdraw`, `GET …/licences/coverage`.
  - An `@ApiResponse` for every arm: 400, 403, 404, 409 `licence-number-taken`, 409 `licence-withdrawn`, 409 `client-departed`, 409 `idempotency-key-reuse`.
  - `need` and `kind` are API enums. Commit `openapi:export`.
- **Worker:**
  - `LicenceExpiryWorker`, env `LICENCE_EXPIRY_POLL_MS` (off when unset), in the `WaveCutoffSweepWorker` shape.
  - It enumerates tenants with `select distinct tenant_id from licences where status = 'active' and valid_until is not null and valid_until <= $today + 60 and (upcoming_warned_on is null or expired_warned_on is null)` on the auth database, then calls `sweepExpiry` per tenant in a try/catch.
  - `JobsModule` imports `ComplianceModule`.
- **Notifications:**
  - Source `licence-expiry`, with `resolves: ['licence.expiry_warning_cleared']` and `SOURCE_RESOLUTIONS` `['renewed', 'withdrawn', 'expired']`.
  - The summary is `{licenceId, kind, number, holder, holderName, siteCode?, validUntil, state}`, with `warehouse_id` set for site and premises licences.
  - `notifications.dto.ts` gets a summary DTO, an entry DTO, the `NOTIFICATION_ENTRY_DTOS` entry and the discriminator.
  - Pinned in `test/notifications.spec.ts` (vocabulary, resolutions, audience).
- **Web:**
  - **`/compliance?tab=licences`**, a new tab in `compliance-tabs.tsx` (plus the `lib/page-tabs.ts` entry and its test):
    - **Gaps first**, worded from `coveredBy`, e.g. `ACME at WH-PUN — client licence needed: Form 20G (2 SKUs)`. When there are none: `All drug and food goods are covered`.
    - **Then the table:** holder, site, kind label, number, valid from/until, the server's `expiryState`/`daysLeft` badge, and the note. Dates use `formatIstDate`. The browser clock is never used.
    - **Add:** a holder picker (a client other than `self`, plus an optional site; or a site), kind, number, dates and note. Edit works the same way. Withdraw uses `ConfirmRow`.
  - **`lib/licences.ts`:**
    - `parseLicenceDraft`, mirroring the number and date rules, with the regexes pinned to the backend's in a test;
    - kind and need labels as `Record` over the generated unions;
    - unknown kinds or needs dropped at mapping;
    - `licenceReason(error, action)` covering every route arm, plus `unauthenticated`, `conflict` and transport errors.
    - The edit form takes one idempotency key per draft, cleared on change and on success (`client-contacts.tsx:272`).
  - **Capability:** add `licences.manage` to `CAPABILITIES` and `OWNER_ONLY_CAPABILITIES` in `lib/users.ts`, then run `check:capability-mirror`.
  - **Notifications:** the `licence-expiry` entry in `lib/notifications.ts` (category, description, href to the tab), plus its `notifications.test.ts` case. `lib/audit.ts` gets a label for the `licence` target.
  - Run `api:generate`.

**Never:**
- No blocking of any work (1-6d).
- No document upload (it goes to the file-storage story with 2.5).
- No portal access.
- No email or push.
- No per-licence lead time.
- No handheld change.
- No licence on documents.
- No dashboard tile.
- No client–warehouse assignment table.
- No unscheduled (OTC), homoeopathic or AYUSH licence forms (PENDING).

## I/O & Edge-Case Matrix

Client C, sites W1 and W2. IST today is 2026-11-01. The "goods" column means stock on hand or an open PO/ASN.

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Add FSSAI | C, `fssai-state`, `10012345678901`, until 2027-03-31 | 201, audited | N/A |
| Registration prefix | `fssai-registration`, `10012345678901` | refused | 400 `validation-failed` |
| Premises licence | C + W1, `drug-20b`, `mh/pun/20b  12` | 201, number `MH/PUN/20B 12` | N/A |
| NDPS without expiry | `ndps`, no `validUntil` | refused | 400 |
| Self holder | `clientId` = self | refused | 400 |
| Departed holder | departed C | refused | 409 `client-departed` |
| Unknown holder or licence | another tenant's client; PATCH an unknown id | refused | 404 `not-found` |
| Family duplicate | active `fssai-state` N; add `fssai-central` N | refused | 409 `licence-number-taken` |
| Edit number clash | PATCH a number to another active one | refused | 409 |
| Clear FSSAI expiry | PATCH `{validUntil: null}` on FSSAI | refused | 400 |
| Edit withdrawn | PATCH or withdraw a withdrawn licence | refused | 409 `licence-withdrawn` |
| Not owner / portal | ops_manager POST / portal GET | refused | 403 `role-denied` |
| Gaps: where goods are | C has food stock at W1 only; nothing recorded | gaps: client C@W1 fssai, site W1 fssai; nothing for W2 | N/A |
| Gaps: open ASN | C's food on an open ASN into W2, no stock | gaps for W2 | N/A |
| Gaps: premises scope | C holds FSSAI for W1 only; goods at W1 and W2 | client gap at W2 only | N/A |
| Gaps: head office | C holds FSSAI with no site | no client gaps | N/A |
| Gaps: Schedule X | both hold `drug-20b`; an `X` SKU at W1 | `drug-20g` gaps, client and site | N/A |
| Gaps: self | self food at W1 | site gap only | N/A |
| Gaps: expired / future / registration | C's FSSAI until 2026-10-31; one from 2026-12-01; W1 holds a registration | gap; gap; W1 covered | N/A |
| Sweep day 61 | until 2027-01-01 | nothing | N/A |
| Sweep day 60 | until 2026-12-31 | one upcoming; a second run raises nothing | N/A |
| Sweep expiry day | until 2026-11-01 | upcoming | N/A |
| Sweep expired | until 2026-10-31, upcoming open | the upcoming entry clears (`expired`); one expired opens | N/A |
| Sweep exclusions | withdrawn; departed client; until before its added date; successor valid on until+1 | nothing | N/A |
| Renewed | edit until → 2028-03-31 with an open warning | entry resolved `renewed`; dates reset | N/A |
| Typo within window | until 12-31 → 12-30, upcoming already warned | no clear, no re-raise | N/A |
| Withdraw warned | withdraw with an open warning | entry resolved `withdrawn` | N/A |
| Notification audience | any raise | the owner gets the entry; ops_manager does not | N/A |

</frozen-after-approval>

## Code Map

All backend paths are under `workspace/core/backend/wms-be/`.

- **Precedent:**
  - `schema.ts:396–411` (`client_contacts`);
  - `drizzle/0077_client_master_record.sql:116–128` (the RLS client clause), `0083_sku_goods_type.sql:46, 182, 296` (fail-fast, probe sentinel, named refusals);
  - `clients.command.ts:747–1006` (the skeleton, no-op `:887`), `api/clients.controller.ts:377–491` (the staff-only read pattern `:382`);
  - `tenant-session.guard.ts:72` (portal refusal).
- **Holders:**
  - `clients.facade.ts:321` (`assertClientInTenantInTx`), `:495` (`departedClientIdsInTx`), `:505` (`clientDeparted`), `:680` (`not-found`);
  - `tenancy.service.ts:120` (`warehouseNotFound`) and `assertWarehouseInTenant`;
  - `schema.ts:296–312` (`self` / `system_owned`), `:554` (warehouses).
- **Goods:** `segregation.ts:235–240` (`isFood`, `isDrug`); `goods-type.ts:26`; `stock_on_hand` (`schema.ts:1520`); the open PO/ASN status vocabularies in `schema.ts` (`purchase_orders`, `asns`).
- **Capability:** `tenancy/permissions.ts:222, 301, 310`. Web: `lib/users.ts:15`, `OWNER_ONLY_CAPABILITIES ~:216`.
- **Audit:** `shared/primitives/audit.ts:44` (`AUDIT_TARGET_TYPES`), `:194–204`; `test/support/audit-guard.ts:61` (`AUDIT_NO_OP_ARMS`); `test/architecture.spec.ts:2969–3009`.
- **Module graph:** `tenancy.module.ts:4` (tenancy imports compliance, so compliance must not import catalog or tenancy modules); `excursion.command.ts:20` (free-function and direct-read precedent).
- **Jobs:** `jobs/jobs.module.ts:1100–1146` (the worker template, facade call), `:1478–1510` (imports, providers). Do not copy `replenishment.expiry.scan.ts:357` (UTC); copy its raise and outbox shape `:298, 321`.
- **IST:** `shared/primitives/time.ts:11, 21, 50`.
- **Notifications:**
  - `notification-sources.ts:23` (types), `:54–79` (`SourceSpec`, `SOURCE_RESOLUTIONS`), `:268–276`, `:428` (batch-alert decoder), `:662–676` (audience);
  - `notifications.delivery.ts:134–163` (upsert on `(tenant, source_type, source_id)`; a re-raise is a no-op);
  - `schema.ts:5417`; `api/notifications.dto.ts:181–225`;
  - `test/notifications.spec.ts:365–387`.
- **Web** (`workspace/core/frontend/wms-fe/src/`):
  - `components/compliance/compliance-tabs.tsx`, `lib/page-tabs.ts` (+ test);
  - `client-contacts.tsx:61–298`, `confirm-row.tsx:36, 66`;
  - `lib/clients.ts:106` (the "Your company" label), `:604, 1001` (`not-found` arms);
  - `lib/notifications.ts:29–44, 81, 156, 249`, `notifications.test.ts:155`;
  - `lib/rate-cards.ts:96` (`formatIstDate`);
  - `lib/audit.ts`;
  - `ci.yml:43–71` (the drift guard checks out BE main).

## Tasks & Acceptance

**Execution:**
- [x] `wms-be drizzle/0084_licences.sql` + schema + meta -- the table, CHECKs, family unique, RLS and its probe arm, the source widening -- decisions 5–7
- [x] `wms-be src/shared/primitives/licence.ts` (+ spec) -- kinds, needs, numbers, validity, coverage, warning state -- decisions 1–3, 6, 7
- [x] `wms-be src/modules/compliance/{licence.command,licence.facade}.ts`, module export, `src/api/licences.controller.ts` + DTOs, permissions, audit vocabulary -- master, coverage, sweep -- decisions 2, 4, 5, 8–11
- [x] `wms-be jobs/jobs.module.ts`, `notifications/notification-sources.ts`, `api/notifications.dto.ts` -- the worker, the source with resolutions -- decisions 3, 8
- [x] `wms-be test/licences.spec.ts`, `test/notifications.spec.ts`, `openapi/openapi.json` -- every matrix row, the pins, the export
- [x] `wms-fe` the compliance Licences tab, `lib/licences.ts` + hook (+ tests), the notification entry, the audit label, the capability mirror, regenerated types
- [x] meta `docs/design/modules/compliance.md` (licences: owns, seam, flows as sequence diagrams, invariants), `notifications.md`, `API-SURFACE.md`, `PENDING.md`, `docs/repos/wms-be/README.md` §Interface Contract, `docs/repos/wms-fe/README.md` §Interface Contract
  - PENDING entries: OTC/homoeopathic/AYUSH forms; whether Schedule X also needs 20B/21B; brands sharing one licence; a departed client's open warning; the dashboard tile; email/push; the portal view; documents; the 1-6d pointer; Epic 18 (controlled & licensed goods) extends this `licences` table rather than adding its own licence admin.

**Acceptance Criteria:**
- Given a two-site tenant with food stock for C at W1 only and no licences, when the owner opens Compliance → Licences, then only C@W1 and W1 gaps are listed. After adding the covering licences, the tab reads "All drug and food goods are covered".
- Given a licence 60 days from expiry and the worker running, when the sweep runs twice that day, then the owner has exactly one open entry. After it expires, that entry is resolved and one expired entry is open.
- Given any receipt, order or other existing flow, when it runs, then its behaviour and responses are unchanged.

## Implementation Notes

Implemented 2026-10-20 against this spec (wms-be, wms-fe, meta docs; no handheld change). Where the build departs from or sharpens the text above:

- **Idempotency key reuse is `422 idempotency-key-reuse`**, the house code (`idempotencyKeyReuse()`), not 409 as the Boundaries list says; the OpenAPI documents 422 beside `409 conflict` (a concurrent same key).
- **The RLS site-row proof runs as `wms_rls_probe` in `test/client-isolation.spec.ts`**, not in 0084's `DO $$` probe: the migrator is a superuser and bypasses RLS. 0084's probe covers every CHECK, the family index and the source-type widening, each refusal by its named constraint. The policy count pin moved 117 → 118.
- **The add's holder checks:** `assertClientInTenantInTx` (404) → `self` (400) → `assertWarehouseInTenant` (404) → `assertClientTakesWorkInTx` (`FOR KEY SHARE`, departed → 409 `client-departed`) → replay again. The "lock" for an add is that client gate; a site licence locks nothing (the family index and the key settle a duplicate).
- **Edit and withdraw lock the licence row `FOR UPDATE`** and replay again under it; a same-key withdraw race is pinned (parked waiters, one effect, one key, mutation-checked by deleting the second replay).
- **`licenceClock`** (`licence.command.ts`, the §7c mutable clock) is the "today" of the edit's warning comparison and of every read's `asOfDate`. The worker's `tick(today?)` takes the date for the suites.
- **The family-unique index is SQL-only** (an expression index, the 0078 precedent), so `db:generate` stays clean.
- **Coverage:** the goods (stock `quantity > 0`, an open PO with an open line, an ASN `announced | partially_received`) are filtered to drug or food SKUs in SQL; needs and coverage are decided in TS by the primitive (`needsOf`, `clientLicenceCovers`, `siteLicenceCovers`), so the rule exists once. Gaps are ordered per site: the site's gaps, then each client's, needs in vocabulary order.
- **Sweep detail:** an expired raise on a term never warned upcoming (the worker was off) also stamps `upcoming_warned_on`, so the row leaves the due set. The successor rule is per (client, site, need) as decided; a head-office licence is not treated as the successor of a premises one (PENDING).
- **E2E dates** are relative to the real IST date + 12 days, so "added today" is never a historical record whatever day the suite runs.
- **Web:** the gaps and the table share one hook (`useLicences`, both reads in parallel); the tab renders `AllClientsNote` (licences are never filtered by client).


## Spec Change Log

## Review Triage Log

**Design review, 2026-10-20.** Three reviewers: backend (B1–B14), domain and edge cases (E1–E14), web and contracts (F1–F14). 42 raw findings, 31 after merging duplicates. Three needed the user (premises scope, site scope, `self`; answered the same day). The rest are patched above or sent to PENDING. Re-checked by hand:
- the notification upsert keyed on `(tenant, source_type, source_id)` ignores a re-raise (`notifications.delivery.ts:150–163`, `schema.ts:5417`);
- both holder 404s answer `not-found` (`tenancy.service.ts:122`).

- D1 critical (B1, F1): one source id per licence would swallow the expired and renewed warnings, and entries never resolve. Fix: a per-raise `warningId`, a resolve event and outcomes (decision 8).
- D2 high (B2, F4): the 404 codes don't exist. Fix: `not-found`, plus an unknown-licence row.
- D3 high (E3, B3, F12) → user: `self` is covered by the site licence (decision 4).
- D4 high (E1, E12, E13) → user: client licences may name their premises (decision 2).
- D5 high (E2, B11) → user: gaps only where the goods are (decision 2).
- D6 high (F3): "reads ungated" leaked to the portal. Fix: staff only, portal 403 (decision 11).
- D7 high (F2): the notification DTO union was missing. Fix: named in the code map and tasks.
- D8 med (E5, B4): weak FSSAI checks and case-sensitive uniqueness. Fix: the prefix per kind, normalisation, uniqueness per family (decision 7).
- D9 med (E6): NDPS has a fixed validity, and the drug retention deadline was hidden. Fix: NDPS requires `validUntil`; the drug form's date is labelled as the retention date (decision 6).
- D10 med (E7, B9): departed holders and successors were undecided. Fix: decision 9.
- D11 med (E8, B14): backfilled and future licences; an inexact boundary. Fix: an exact rule (decision 3); historical records are skipped (decision 9).
- D12 med (B5, F10): PATCH null semantics and the hash. Fix: decision 10 and the hash arms.
- D13 med (B6): re-replay under the lock, withdraw of a withdrawn licence, the departed holder, `AUDIT_NO_OP_ARMS`. Fix: specified.
- D14 med (B7): the audit target type and the sweep's actions. Fix: named.
- D15 med (B8): the worker can't call an `…InTx` method. Fix: `sweepExpiry` opens its own transaction; module export and import; a filtered tenant enumeration.
- D16 med (B10): module imports would cycle. Fix: direct reads plus free functions; no new import.
- D17 med (F5, F6): the reason-map arms; field naming would need prose parsing. Fix: the full arm list and a client-side `parseLicenceDraft`, pinned.
- D18 med (F7): the surface's location was implicit. Fix: `/compliance?tab=licences`.
- D19 med (F8): the browser clock would disagree with the sweep. Fix: the server serves `asOfDate`, `expiryState` and `daysLeft`.
- D20 med (F9): the web would mirror the rule table. Fix: `coveredBy` on each gap; `Record` labels over the generated unions.
- D21 med (E4): OTC, homoeopathic and AYUSH goods, and whether X also needs 20B/21B. Fix: stated in Never; to PENDING.
- D22 low (E9): a re-warn on a typo within the window. Fix: decision 10's state comparison.
- D23 low (E10): withdrawn warned state. Fix: withdraw resolves the entry.
- D24 low (E11): kits. Gaps come from stock and open documents, and kits hold neither.
- D25 low (E14): missing matrix rows. Added.
- D26 low (B12): cost; an injectable today; the need vocabulary. Fix: SQL filtering, `istToday?`, `LICENCE_NEEDS`.
- D27 low (B13): the RLS site-row proof. Fix: a probe arm.
- D28 low (F11): the key per draft. Fix: specified.
- D29 low (F13): the mirror anchors and the CI ordering. Fix: corrected; noted in Verification.
- D30 low (F14): the contract sections. Fix: named.
- D31 low (E5 note): a site holding only a registration is covered, since any tier covers; the user's decision 1 stands.

**Code review, 2026-10-20.** Three layers: blind hunter (H1–H14), edge-case hunter (C1–C9), verification gap (V1–V5). 28 findings, 19 after merging duplicates: 8 patched, 2 deferred, 9 rejected. No loopback: decision 9 settled only when a warning is *raised*; the skip handling is a direct fix inside that intent. Re-checked by hand: `purchase_order_lines` has `received_qty` and `ordered_qty` beside its `status` (`schema.ts:2249–2253`), so status alone does not mean "goods to come".

- V5 / H1 / H2 / C1 / C2 / C3 high, patch: a skipped due row (successor, departed client, historical) never resolves an open warning and never leaves the due set. The owner's entry stays open forever, and the tenant is re-swept every tick. Fix: skips suppress only raising. A successor clears the open warning (`renewed`). Expiry supersedes an open upcoming warning (`expired`). Skipped rows are stamped warned with no raise. Three e2e cases.
- H3 / C4 medium, patch: an edit that moves `validUntil` into the past resolves the warning as `renewed`. Fix: the outcome follows the implied state; e2e added.
- C9 medium, patch: a fully received line on an open PO keeps raising gaps. Fix: `received_qty < ordered_qty`.
- V1 medium, patch: the expired step was driven through the facade, not the worker, so a worker filter that drops expired-only rows would go unnoticed. Fix: drive it through `worker.tick`.
- V2 / H4 medium, patch: no test renews an expired-warned licence. Fix: e2e added.
- V3 / H6 medium, patch: the coverage arm for open PO lines was never exercised. Fix: "Gaps: open PO" e2e.
- V4 / H11 medium, patch: the web Edit → Save path was untested. Fix: a component test for the PATCH body, the key and the disabled fields.
- C5 low, patch: the worker hard-codes 60. Fix: use the constant.
- H12 low, patch: the README poll value contradicts `.env.example`. Fix: made consistent.
- H5 low, defer: goods arriving by transfer, and returns, are not in the coverage set. Decision 2 names stock and open PO/ASN only. Deferred-work entry.
- H7 low, defer: licence edits keep no before/after history, because `audit_events` has no details column. Pre-existing audit design. Deferred-work entry.
- H8 / C7 low, reject: the 500-row list cap is silent. Reaching it is unlikely, and a `truncated` flag is new public surface.
- H9 low, reject: the coverage read is unbounded. It is catalog-scale and read on tab open; nothing shows it is slow.
- H10 / C8 low, reject: the list and coverage reads can straddle IST midnight. The badges come from the list's own `asOfDate`; a mismatch lasts one refresh.
- H13 low, reject: FSSAI numbers typed in grouped form are refused. Decision 7 collapses spaces; the error names the 14-digit rule.
- H14 low, reject: the notification links to the tab, not to the row. Cosmetic.
- C6 low, reject: a punctuation-only drug number is accepted. Unlikely in use, and the fix touches the CHECK, the probe and the web mirror.
- H8b (the agent's report) false: "two expiring licences of one kind silence each other". A successor must be valid on `validUntil + 1`, so the later-expiring licence still warns and the earlier one is muted only while the later one covers it.

## Design Notes

- **Why per-raise warning ids.** A notification row is unique per `(source_type, source_id)`, and a re-raise is a no-op. A fresh id per warning, closed by a resolve event, gives each term its own entry and keeps the bell honest.
- **Why gaps only where the goods are.** There is no client–warehouse assignment, so counting every SKU at every site would invent gaps at sites that hold nothing. 1-6d will enforce per receipt and per order at a site, which is the same scope.
- **Why compliance reads other tables directly.** Tenancy imports compliance, so importing the catalog or tenancy modules would cycle. Reads never cross the write boundary, which is what the architecture rule guards.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run db:migrate && bun run db:generate` -- expected: 0084's probe passes; no changes
- `bun run lint && bun run typecheck && bun run test` (one jest run at a time) -- expected: green
- `cd workspace/core/frontend/wms-fe && bun run api:generate && bun run lint && bun run typecheck && bun run test && bun run check:capability-mirror` -- expected: green. The FE CI's generated-client and capability-mirror checks stay red until the BE PR merges.
