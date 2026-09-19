# Sprint Change Proposal — 3PL into the epics (Epic 21)

**Date:** 2026-09-19 · **Trigger raised by:** Sasidhar · **Workflow:** bmad-correct-course
**Source design:** `_bmad-output/specs/spec-3pl/` (SPEC, schema, billing-model, architecture — written 2026-09-18)
**Mode:** Batch (all proposals presented together, per this session's working convention)

---

## 1. Issue Summary

The product's largest go-to-market gap is **3PL**: a warehouse that stores and ships *other companies'* goods and bills them for it. Sasidhar's direction on 2026-09-19: *"plan 3PL in to the epics — it is very important for go to market."*

What the analysis found:

1. **Zero epic coverage.** All twenty epics (1–9 + expansion 10–20) assume a single stock owner per tenant. Nothing covers per-client billing, client-scoped inventory separation, a client portal, inbound ASN, or per-client SLA reporting. The 3PL spec's own audit is confirmed: *zero of the twenty epics cover it.*
2. **The spine's reassurance is false as written.** `ARCHITECTURE-SPINE.md` (Deferred section, :286) claims *"3PL multi-client billing (v2) stays reachable through AD-3 tenancy — no single-client assumptions anywhere."* Verified against the code and the spine text: **AD-3 is `tenant_id` + `warehouse_id` only; clients are not tenants.** A client shares the warehouse, bin grid and operator workforce — making each client a tenant would forfeit cross-client waves, which are most of a 3PL's efficiency. Client is a **third scoping dimension that does not exist**, and today's RLS (keyed on `app.tenant_id` alone) cannot enforce it.
3. **A complete design already exists** and needs ratifying, not re-deriving: CAP-1..10, schema with `client_id` placement table and two migrations (A: dimension + backfill; B: billing/ASN/portal, additive), the billing model (4 charge codes, draft→issued immutable invoices, SAC services codes), and three spine decisions **AD-23/24/25**.
4. **Why now, not later:** the client dimension is **migration-shaped** — it touches `skus`, `orders`, `purchase_orders`, `ledger_events` with a NOT NULL + backfill, exactly like Epic 10's quantity migration. Every ledger-writing epic built before it (5, 8, 13, 19, 20…) is one whose new tables and writers must be revisited. Landing it in Phase 0 means Phase 3's 52 stories are all born client-ready and never need a second backfill.

---

## 2. Impact Analysis

| Artifact | Impact |
|---|---|
| **PRD** | Four statements become wrong or stale: :37 (3PL as non-user/"v2 wedge"), :443 ("No 3PL multi-client billing in v1"), :468/:471 (future-possibility framing). All four get dated amendment notes pointing at Epic 21. |
| **Architecture spine** | AD-23/24/25 appended after AD-22 (PROPOSED, same as the 2026-09-17 expansion's AD-19..22); the false AD-3 Deferred claim corrected; `clients`/`billing` module rows added to the spine's module mapping. |
| **Epics** | New **Epic 21** (list entry + FR coverage map + dependency flow + execution order + hard gates). New FR-75..FR-82 appended to the requirements inventory. |
| **Sprint status** | New epic-21 block with 8 story keys at status `backlog` (checklist item 6.4). |
| **MVP scope** | **+2 stories in Phase 0** (21-1, 21-2 — the migration pair). Phase 1 unchanged at 17 stories. Billing/portal/ASN/reporting (21-3..21-8) become **Phase 2's first delivery**, run parallel to Phase 1 — they are additive and do not gate ~30-to-market. |
| **Code** | None yet. Epic 21-1 is the second one-shaped migration (18→~22 quantity/scope columns); it lands after Epic 10's migration is merged and stable. |

**Epic-21 story breakdown** (backend-first inside the epic; surfaces ride their epic):

| Story | Delivers | Phase |
|---|---|---|
| 21-1 | Client dimension migration — `clients` table, system-owned `self` client per tenant, `client_id NOT NULL` on `skus`/`orders`/`purchase_orders`/`ledger_events` + backfill, `bins.dedicated_client_id`, `users.client_id` (migration A) | 0 |
| 21-2 | Client isolation — second RLS session variable `app.client_id`, fail-closed policies, DB-level isolation probe; operator sessions unchanged | 0 |
| 21-3 | Rate cards — versioned, closed `charge_code`/`basis` vocabularies | 2 |
| 21-4 | Metering + daily storage snapshot job (rebuildable projection; replay reproduces it) | 2 |
| 21-5 | Client invoices — draft→issued immutable, SAC services GST, dispute traceability | 2 |
| 21-6 | Advance shipment notices — ASN document beside the PO; GRN books against PO-or-ASN | 2 |
| 21-7 | Client portal — read-mostly portal (stock, orders, invoices) under `app.client_id` sessions | 2 |
| 21-8 | Per-client service reporting — dock-to-stock, pick accuracy, dispatch timeliness from the ledger | 2 |

**New FRs (FR-75..82):** client entity + `self` default (75); client-scoped stock isolation (76); versioned rate cards (77); ledger-derived billing + storage snapshots (78); immutable client invoicing (79); ASN against PO-or-ASN (80); client portal with DB-enforced isolation (81); per-client SLA/service reporting (82).

---

## 3. Recommended Approach

**Direct Adjustment — Epic 21, migration pair in Phase 0, rest additive in Phase 2.** (Scope classification: **Moderate** — backlog reorganisation; executed by the developer agent in this session per convention; no rollback, no MVP-goal change.)

**Rationale:**

- The spec's own sequencing argument is adopted as-is: the client dimension belongs in **Phase 0 beside epics 10/11**, because it is migration-shaped and every later epic inherits it cheaply only if it lands first.
- **Epic numbers stay outside execution order** (the programme's established convention — 10–20 are not renumbered), so 3PL takes the next free number: **Epic 21**.
- Billing/portal/ASN/reporting are additive on top of the dimension and follow demand — they become **Phase 2's first concrete delivery** (Phase 2's placeholder line currently names "billing" with no epic; that ambiguity is resolved: 3PL billing = 21-3..21-5. **Subscription billing remains uncovered** — distinct product, PRD open question OQ4 stays open).
- **Effort:** 2 stories added to Phase 0 (13→15); 6 stories to Phase 2. **Risk:** the backfill migration is the programme's second one-shaped migration — mitigated by landing it immediately after Epic 10's (same review machinery, same migration checklist). **Timeline:** Phase 0 grows by ~2 stories; market timeline (~30 to market) unchanged.

---

## 4. Detailed Change Proposals

### 4.1 Architecture spine — `ARCHITECTURE-SPINE.md`

**(a) Append after AD-22** (same PROPOSED format as the 2026-09-17 expansion entries; full text from `spec-3pl/architecture.md`):

> **AD-23 — Client is a scoping dimension inside the tenant, defaulted and never nullable** `[PROPOSED]`
> - **Binds:** all repos; CAP-1, CAP-2, CAP-3
> - **Prevents:** cross-client leakage; a per-tenant "3PL mode" branch through every command
> - **Rule:** every tenant has exactly one **system-owned `self` client**, created with the tenant. `client_id` is `NOT NULL` wherever it appears. **D2C is the one-client case of the 3PL model, not a separate mode** — no command, query or surface branches on whether the tenant is a 3PL.
> - **Why not nullable:** a nullable scoping column makes every read carry `OR client_id IS NULL`, and isolation fails at the one query that forgets. A defaulted non-null column has one code path.
> - **Where it lives:** the SKU is the source of truth; most tables inherit the client by reference. Explicit columns exist only where a query filters or aggregates *without* joining through the SKU — `skus`, `orders`, `purchase_orders`, `ledger_events`; `bins.dedicated_client_id` and `users.client_id` nullable by design.
>
> **AD-24 — Client isolation is enforced by a second RLS session variable** `[PROPOSED]`
> - **Binds:** wms-be; CAP-2, CAP-8
> - **Prevents:** a portal query, report, export or background job returning another client's rows
> - **Rule:** RLS policies gain a client clause keyed on `app.client_id`: an **operator session** leaves `app.client_id` unset and sees the whole tenant (cross-client waves and floor work untouched); a **client-portal session** sets it, and the database — not the application — makes another client's rows unreachable. Same fail-closed `NULLIF(current_setting(...), '')` idiom AD-3 already relies on. Scoping extends where AD-3's does: background jobs, projection rebuilds, export workers and reporting all take explicit client context or deliberately none.
>
> **AD-25 — Billing is a projection over the ledger** `[PROPOSED]`
> - **Binds:** wms-be; CAP-5, CAP-6, CAP-7
> - **Prevents:** a billing book that drifts from the movements it bills for
> - **Rule:** charges derive from ledger events plus the rate card in force. Handling charges are **already ledger events** (`grn.received`, `pick.picked`, `order.dispatched`) — metering is aggregation, not new instrumentation. Storage needs duration, so a **daily snapshot job** records billable units per client per day; that snapshot is a **rebuildable projection, a cache and not a book**, and replaying the ledger must reproduce it. An **invoice is a materialised snapshot** recording its inputs, immutable once issued. Reuses AD-21's register-as-projection precedent — one mechanism, not two.

**(b) Correct the false Deferred claim (:286).**

OLD: `3PL multi-client billing (v2) stays reachable through AD-3 tenancy — no single-client assumptions anywhere`
NEW: `3PL multi-client billing is planned as Epic 21 (correct-course 2026-09-19) — client is a third scoping dimension AD-3 does not provide; see AD-23/24/25`

**(c) Rider fix (found during this analysis):** the Consistency Conventions table still reads `base-UoM x 10^6` — stale since AD-9's amendment to milli-units (×10³). Correct to `base-UoM x 10^3`.

**(d) Module mapping:** add `clients` (client entity, portal scoping; owns `clients`) and `billing` (rate cards, metering, snapshots, invoices; reads the ledger through the inventory facade, writes no stock) rows; `inbound` gains the ASN document beside the PO.

### 4.2 Epics — `epics.md`

**(a) Requirements inventory** — append after the Tier 4 block:

> **3PL — added by correct-course 2026-09-19 (Epic 21)**
> FR75-82: Epic 21 — Client entity + self default, client isolation, rate cards, ledger-derived billing, immutable invoicing, ASN, client portal, per-client reporting

**(b) Epic list** — append after Epic 20:

> ### Epic 21: 3PL — Clients, Billing & Client Portal `[PHASE 0 → PHASE 2]`
> Clients are a scoping dimension inside the tenant (one system-owned `self` client per tenant — D2C is its one-client case); billing derives from the ledger and the rate card; invoices are immutable once issued. **Migration pair (21-1, 21-2) is Phase 0**; rate cards, metering/invoicing, ASN, portal and per-client reporting are additive in Phase 2 by demand.
> **Surfaces:** web — client admin, rate cards, invoice review, ASN, per-client dashboards; mobile — none new (floor work is deliberately client-agnostic; cross-client waves untouched).
> **FRs covered:** FR-75, FR-76, FR-77, FR-78, FR-79, FR-80, FR-81, FR-82

**(c) Dependency flow** — extend the expansion sentence with: `Epic 21 ← 1+2 (migration pair 21-1/21-2 in Phase 0; 21-3…21-8 ← 21-1+21-2, additive)`.

**(d) Execution order block** —

OLD:
```
PHASE 0  Epic 10 → Epic 11                       foundations (13 stories)
PHASE 1  4-2d → 4-6c → 4-6d → Epics 5,6,7,8,9    MVP        (17 stories)  ← ~30 to market
PHASE 2  billing · production ops · data onboarding           (no epic covers these; run parallel to Phase 1)
```
NEW:
```
PHASE 0  Epic 10 → Epic 11 ∥ Epic 21-1,21-2      foundations (15 stories; 21 = client dimension migration)
PHASE 1  4-2d → 4-6c → 4-6d → Epics 5,6,7,8,9    MVP        (17 stories)  ← ~30 to market
PHASE 2  Epic 21-3…21-8 (3PL billing, ASN, portal, reporting) · production ops · data onboarding   (run parallel to Phase 1)
```

**(e) Hard gates line** — add: `Epic 21-1/21-2 before 21-3…21-8` (the migration pair gates the rest of the epic; nothing else changes).

### 4.3 PRD — dated amendment notes (history preserved, not rewritten)

| Line | Old | Amendment |
|---|---|---|
| :37 (non-users) | `3PLs running many client brands with per-client billing — a v2 wedge, not v1.` | *(Amended 2026-09-19: 3PL is planned — Epic 21; see epics.md and SPEC-3pl.)* moved out of non-users |
| :443 (non-goals) | `**No 3PL multi-client billing** in v1 — tenancy is designed for it…` | *(Amended 2026-09-19: the client dimension lands in Phase 0 as Epic 21-1/21-2; billing/portal follow in Phase 2 — Epic 21.)* |
| :471 (future) | `3PL billing (v2 candidate; tenancy prepared)` | *(Amended 2026-09-19: covered by Epic 21 — rate cards, metering, invoices; billing as a ledger projection, AD-25.)* |
| :468 (future) | `EDI flows (v2+; enterprise/3PL wedge)` | *(Amended 2026-09-19: the 3PL wedge is now Epic 21; EDI 940/945/856 itself stays out — ASN is API-native.)* |

### 4.4 Sprint status — `sprint-status.yaml`

New `epic-21` block (8 story keys, 21-1…21-8, all status `backlog`) beside epics 10/11; the expansion comment block's PHASE 0/PHASE 2 lines updated to match §4.2(d).

### 4.5 Handoff notes for story specs

When Epic 21 stories are specced, their `context:` frontmatter must include `_bmad-output/specs/spec-3pl/` (all four files) — the spec is the design source; the spine ADs are its ratified summary. 21-1's spec additionally carries the migration checklist and the AD-9-amendment precedent for one-shaped migrations.

---

## 5. Implementation Handoff

**Scope: Moderate** — backlog reorganisation, executed in this session (developer/PO role, per convention): apply §4 edits → update sprint-status.yaml (checklist item 6.4) → commit on the meta repo's current branch (docs are meta-only; no child-repo change yet, so meta commit is the whole change) → update the multi-domain-expansion memory with the 3PL decision.

**Success criteria:** spine carries AD-23/24/25 with the false claim corrected; epics.md carries Epic 21 end-to-end (inventory → list → flow → order → gates); PRD lines carry dated amendments; sprint-status has the epic-21 block at `backlog`; no story work starts until 10-4's PR merges and 10-5/10-6 complete — Epic 21-1 is the next Phase-0 slot after the current queue.