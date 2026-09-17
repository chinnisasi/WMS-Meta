# Sprint Change Proposal — Multi-Domain Platform Expansion

**Date:** 2026-09-17
**Author:** Claude (correct-course workflow), decisions by Sasidhar
**Status:** Awaiting approval
**Scope classification:** **Major — PRD rewrite**, one foundational migration, eleven new epics

> **Supersedes** the first draft of this file (same date), which was written against a five-domain list and concluded "everything is additive". The expanded domain list invalidated that conclusion: measured goods make the quantity model a blocking migration. That draft's analysis survives inside Tier 1; its central claim does not.

---

## 1. Issue Summary

**Trigger.** Asked directly during sprint execution, after story 4-6b closed: does the schema support medical, apparel, ecommerce, spares and cold chain? Investigation said no — discrete general merchandise only. The target was then widened again to roughly twenty-five domains spanning consumer retail, food and agriculture, industrial and manufacturing, and regulated storage.

**Issue type:** Strategic pivot. The product moves from *a WMS for India D2C sellers* to *a multi-domain warehouse platform*. Nothing built is wrong; the target moved.

**What the domain list actually demands.** Twenty-five domains, but only eight distinct capability clusters:

| Cluster | Driven by | Disposition |
|---|---|---|
| **A — Fractional + catch-weight quantities** | grain, fertilizer, seeds, cement, chemicals, petroleum, LPG, bulk alcohol; meat, seafood, dairy, produce; steel/pipe by length | **Tier 0 — blocking** |
| **B — Storage conformance & segregation** | mixed temp zones; hazmat (chemicals, LPG, ammonium nitrate, ammunition); secure cages (electronics, jewellery, controlled drugs); yards and floor stacking (construction, furniture, agri) | Tier 1 |
| **C — Duty, excise & customs status** | bonded, FTZ, alcohol, tobacco, petroleum | Tier 3 |
| **D — Controlled & licensed goods** | NDPS controlled drugs, ammunition, explosives precursors, alcohol | Tier 3 |
| **E — Returnable assets / containers** | LPG cylinders, kegs, pallets, dairy crates | Tier 2 |
| **F — Manufacturing-adjacent** | WIP states, JIT sequencing, MRO | Tier 4 |
| **G — Handling & dimensional capacity** | bulky goods, floor stacking, heavy pallets, white-glove | Tier 1 (inside B) |
| **H — Seasonality & forecasting** | books, media, toys | Amends Epic 6 |

### Evidence (verified against the working tree)

| # | Gap | Verified at |
|---|---|---|
| 1 | All 18 quantity columns are `integer`; `uom_conversions.factor` is `integer` | `schema.ts`, `factor` at `:317` |
| 2 | `integer` **overflows before silo scale** — 2,147,483,647 g ≈ 2,147 t | int4 range; a grain silo holds far more |
| 3 | Batch + serial together is **hard-refused at pick** | `pick.command.ts:708` |
| 4 | No storage class; `bins.type` is free text with **no CHECK** | `schema.ts:211-212`; no `bins_type_check` in any migration |
| 5 | No returns/RMA in schema or any of the 9 epics | grep returns only false positives |
| 6 | No variants, kits, physical attributes, or country of origin | `schema.ts:271-296` |
| 7 | **No shipment address anywhere** | `schema.ts:1409`, `:130` — already blocking story 4-6d |
| 8 | Bin capacity is a bare `integer` — no volumetric or weight capacity | `schema.ts:211` |

---

## 2. Impact Analysis

### 2.1 The decision that reshapes the plan: AD-9 is amended

**AD-9 `[ADOPTED]`** states *"quantities are integers in the SKU's base UoM"* and exists to prevent *"quantity-unit ambiguity"*. Measured goods cannot live inside it, and the tiny-base-unit escape fails twice: int4 overflows at silo scale, and **catch weight cannot be expressed at any base unit**.

**Decision: amend AD-9.** This is the one non-additive change in the whole programme, and it is why Tier 0 exists.

**Two features, deliberately separated** — this is what keeps the risky part narrow:

1. **Fractional quantity** — how much of a thing is here. Touches all 18 quantity columns and every command. *This is the migration.*
2. **Catch weight** — the actual weight of an individual handling unit (a case of beef is **one** unit weighing 18.4 kg; handled by unit, priced by weight). This is a **new per-handling-unit field**, additive, and touches nothing existing.

Conflating them would make catch weight part of the migration for no reason.

**Recommended representation — scaled integers, not `numeric`.** Quantities become `bigint` in **micro-units** (base UoM × 10⁶), with each UoM declaring its real decimal precision, and decimals converted only at the API and UI edges.

*Why this rather than `numeric(18,6)`:* the reservation path decrements ATP counters in **Valkey through a Lua script**, and Lua numbers are IEEE doubles — decimal quantities there would reintroduce exactly the float-precision errors AD-9 was written to prevent. Using `numeric` in Postgres and scaled integers in Valkey means two representations and a conversion boundary in the most concurrency-sensitive code in the system. Scaled integers keep one representation everywhere, stay exact under summation, and follow the repo's own **money-as-integer-paise** precedent. `bigint` micro-units reach 9.2 × 10¹² base units — ample for silo and tank scale.

The functional outcome is identical to `numeric`: fractional quantities with declared precision. If you'd rather have true `numeric` in Postgres, say so and I'll re-cut Tier 0 — the epic shape is the same either way.

**The migration has a built-in safety net.** Story 2.2 shipped continuous replay-reconciliation: derived quantities are recomputed from the ledger and compared against live counters. That is precisely the instrument to prove a quantity migration didn't corrupt anything — replay after migration must reproduce every balance. Few systems get to make a change like this with an existing oracle; this one does.

### 2.2 Epic impact

| Epic | Status | Impact |
|---|---|---|
| 1–3 | Complete | **Migration only** (Tier 0 rewrites quantity columns they own). Note: all three still read `in-progress` in sprint-status though every story and retrospective is `done` — stale labels. |
| **4** | 3 stories left | **4-6d depends on new Epic 11** (address + weight/dims). 4-2d and 4-6c unaffected. |
| **5** | Backlog | **Must follow Tier 0.** Transfers, adjustments and counts on the old quantity model would all be rewritten. |
| **6** | Backlog | **Scope grows** — shelf-life, excursion and seasonality alerting (cluster H). |
| **7** | Backlog | **Depends on Epic 11** — Shopify is product→variant; without variants the mapping is lossy by construction. |
| 8 | Backlog | **Overlaps Tier 3** — GST/e-way sits beside customs and excise. |
| 9 | Backlog | Minor — excursion, recall and register reporting join the audit surface. |
| **10–20** | **New** | See §4.2. |

### 2.3 Artifact conflicts

- **PRD — rewrite, not amendment.** §1 Vision, §2 Target User, §2.2 Non-Users and §4 all describe a single-vertical product. The persona set (Priya, Ramesh, Ankit) no longer spans the market. **[Action-needed → PM]**
- **Architecture** — AD-9 amended; five new decisions (AD-18…AD-22); *Deferred* updated.
- **Epics** — eleven new entries, FR coverage map extended, dependency flow restated.
- **UX** — variant-aware surfaces, storage-class and segregation refusals on the scan path, returns, container tracking, register views. **[Action-needed → UX]**

### 2.4 Technical impact

**Tier 0 is invasive by nature** — 18 columns, every command, every DTO, every test, plus the Valkey counter representation. Everything in Tiers 1–4 is additive on top of it.

**Three places touch already-shipped code:** the quantity migration (everywhere), storage-class conformance inside the existing putaway (3.5) and pick (4.3) commands, and deleting the batch+serial refusal at `pick.command.ts:708`.

---

## 3. Recommended Approach

**Selected path: Hybrid — one foundational migration (Tier 0), then Direct Adjustment in tiers.**

| Option | Verdict |
|---|---|
| **1. Direct Adjustment alone** | **Insufficient.** Works for Tiers 1–4, cannot deliver cluster A. |
| **2. Rollback** | **Not viable, not needed.** Nothing built is wrong. |
| **3. MVP Review** | **Adopted in part** — the tiering *is* an MVP discipline: each tier ships and sells before the next starts. |

### Tiered roadmap

```
NOW ──────────────────────────────────────────────────────────────────────────►
4-2d → 4-6c → [TIER 0: Epic 10] → Epic 11 → 4-6d → Epics 12,13,14 → Epic 5,6,7,8,9
               quantity model      product    ↑      storage/returns/    existing
               (BLOCKING)          model    unblocked  traceability      roadmap
                                                    → TIER 2 → TIER 3 → TIER 4
```

| Tier | Epics | Unlocks |
|---|---|---|
| **0 — Foundation** | 10 | Everything measured. **Blocks Epic 5.** |
| **1 — Universal foundations** | 11, 12, 13, 14 | FMCG, grocery, apparel, ecommerce, electronics, furniture, spares, pharma packs, cold chain |
| **2 — High-volume verticals** | 15 (+ Epic 6 amendment) | Beverages, dairy, LPG distribution, seasonal retail |
| **3 — Regulated** | 16, 17, 18 | Bonded/FTZ, alcohol, tobacco, petroleum, controlled drugs |
| **4 — Specialized** | 19, 20 | Automotive/JIT, MRO, raw materials, tank farms, silos |

**Why this order:** Tier 0 first because it is the only thing that gets *more* expensive with delay — every epic built on integers is an epic to rewrite. Epic 11 immediately after because it unblocks a story already parked (4-6d) and gates epic 7. Epic 12 (storage/segregation) before epic 5 so counts and transfers are built once against the finished location model.

**Epic numbering:** new epics take **10–20**, not inserted as 5–15. Renumbering would break every reference across `_bmad-output/implementation-artifacts` (context files, retro files, spec frontmatter, sprint-status keys). Order lives in the plan; `infra-1`/`infra-2` inside epic 4 are the precedent.

---

## 4. Detailed Change Proposals

### 4.1 PRD — rewrite (headline changes only; full pass is PM's)

**§1 Vision — NEW (excerpt):**
> Warehouses in India run on spreadsheets, WhatsApp groups and memory — whether they hold home goods, garments, medicines, spare parts, frozen fish, cement or fuel. Inventory correctness is the same problem everywhere; the disciplines around it are not. An apparel seller drowns in returns, a pharma distributor ships an expired lot, a cold-chain operator breaks a chain nobody can prove, a bonded warehouse cannot say which pallet is duty-paid, a fuel depot measures what a counting system cannot express.
>
> This is a warehouse platform for all of them: one append-only ledger as the source of truth, with domain disciplines — measured quantities, lot-and-serial together, storage-class conformance, returns disposition, duty and excise status — built into that ledger rather than bolted on per vertical.

**§2 Target User — [Action-needed].** Priya/Ramesh/Ankit no longer span the market. Needs at least a distributor persona (regulated, multi-licence) and an industrial persona (yard and bulk).

**§2.2 Non-Users — NEW:**
> - **Defence, classified and strategic-reserve depots** — ammunition and strategic reserves need personnel-clearance handling, classified segregation and a government procurement path. Reachable on Tier 3's foundations, deliberately **not planned**: a different product and a different sales motion.
> - **Process manufacturing execution** — the platform holds WIP as inventory (Tier 4); it does not schedule or execute production.
> - **Retail POS-centric single-store shops** *(retained from v1)*.

**§4 — new requirement blocks:**

| FR range | Epic | Subject |
|---|---|---|
| FR-31…34 | 10 | Fractional quantities; per-UoM precision; catch weight per handling unit; UoM controlled vocabulary |
| FR-35…39 | 11 | Shipment address; physical attributes + country of origin; variants; kits/bundles |
| FR-40…45 | 12 | Storage class; hazmat segregation matrix; secure/cage class; location types (yard, floor-stack); dimensional and weight capacity; excursion capture |
| FR-46…48 | 13 | Return authorization; return receipt and inspection; disposition |
| FR-49…51 | 14 | Batch + serial together; minimum remaining shelf life; recall by batch or serial |
| FR-52…54 | 15 | Returnable containers; handling units; container cycle and deposit |
| FR-55…58 | 16 | Customs status; bonded and FTZ movements; in-bond/ex-bond; duty calculation hooks |
| FR-59…62 | 17 | Excise status and registers; bonded alcohol/tobacco/petroleum movement documents |
| FR-63…66 | 18 | Licence validation; controlled-substance registers; two-person custody; statutory reporting |
| FR-67…70 | 19 | WIP states; JIT sequencing; kit staging for assembly; MRO consumables |
| FR-71…74 | 20 | Bulk storage locations; tank and silo level; temperature-compensated volume; reconciliation of measured stock |

### 4.2 Epics — eleven new entries

**TIER 0**

**Epic 10: Quantity Model — Measured Goods & Catch Weight**
> The one foundational migration. Quantities become fractional (scaled integers in micro-units, decimals at the edges) with each UoM declaring its real precision; catch weight arrives as a per-handling-unit actual weight, distinct from quantity. Replay-reconciliation (story 2.2) is the migration's oracle: every balance must reproduce after the change. Blocks Epic 5.
> **FRs:** FR-31…FR-34

**TIER 1**

**Epic 11: Product & Shipment Model**
> Shipment addresses (order destination, warehouse origin) unblock carrier rating; weight and dimensions unblock labels, manifests and dimensional capacity; a two-level product→variant identity makes size×colour first-class **without touching the ledger**; kits hold stock on components and explode at acceptance. Gates epic 7's channel mapping and story 4-6d.
> **FRs:** FR-35…FR-39

**Epic 12: Storage Conformance, Segregation & Location Types**
> Storage class becomes first-class on SKUs and locations with a controlled vocabulary, enforced in putaway and pick — a frozen SKU cannot enter an ambient bin, an oxidiser cannot sit beside a fuel, by rule not convention. Adds a hazmat segregation matrix, a secure/cage class for high-value and controlled stock, location types beyond bins (yards, floor-stack), dimensional and weight capacity, and temperature-excursion capture as ledger events.
> **FRs:** FR-40…FR-45

**Epic 13: Returns & Reverse Logistics**
> The first reverse flow. Units return under an authorization, are received and inspected scan-first on the existing mobile substrate, and are dispositioned — restocked, quarantined or scrapped — every outcome an auditable ledger event.
> **FRs:** FR-46…FR-48

**Epic 14: Traceability & Shelf Life**
> A SKU can be batch- **and** serial-tracked at once, each serial's lot resolved from its own ledger history — deleting the refusal at `pick.command.ts:708`. Shelf-life policy refuses stock with too little life remaining; recall traces a lot or serial to every location and customer and quarantines what remains.
> **FRs:** FR-49…FR-51

**TIER 2**

**Epic 15: Returnable Containers & Handling Units**
> Cylinders, kegs, crates and pallets are assets that cycle, tracked distinctly from the stock they carry, with deposits and per-customer balances. Handling units also give bulky-goods and pallet operations a unit of movement above the SKU.
> **FRs:** FR-52…FR-54
>
> *Epic 6 amendment (cluster H): seasonality-aware reorder points and aging/expiry dashboards.*

**TIER 3**

**Epic 16: Customs, Bonded Storage & Free Trade Zones** — **FRs:** FR-55…FR-58
**Epic 17: Excise & Duty Control** (alcohol, tobacco, petroleum) — **FRs:** FR-59…FR-62
**Epic 18: Controlled & Licensed Goods** (NDPS, ammunition, licences, custody, registers) — **FRs:** FR-63…FR-66

> All three share one shape: **goods carry a fiscal or legal state that gates movement**, and the state transitions are themselves auditable events. Built on one mechanism (AD-21), not three.

**TIER 4**

**Epic 19: Manufacturing Flows** (WIP, JIT sequencing, MRO) — **FRs:** FR-67…FR-70
**Epic 20: Bulk & Tank Storage** (silos, tank farms, level gauging, temperature-compensated volume) — **FRs:** FR-71…FR-74

**Dependency flow — amended:**
> Epic 10 ← 1+2 (migration). Epic 11 ← 1+2. Epic 12 ← 2+3+11. Epic 13 ← 2+3+4. Epic 14 ← 2+10. Epic 15 ← 2+12. Epics 16/17/18 ← 2+4+12. Epic 19 ← 2+10+11. Epic 20 ← 10+12. Epic 5 ← 2+3+10+12. Epic 7 ← 2+4+11. No epic requires a future epic to function.

### 4.3 Architecture

**AD-9 — AMENDED: Deterministic primitive types `[ADOPTED, amended 2026-09-17]`**
> **Rule change.** Quantities are **fractional**, represented as scaled integers in micro-units (base UoM × 10⁶) and stored as `bigint`; each UoM declares its real decimal precision, and decimal conversion happens **only at API and UI edges**. Money stays integer paise; GST stays basis points; timestamps stay ISO-8601 UTC; ids stay UUIDv7.
> **Why scaled integers and not `numeric`:** the reservation path decrements ATP counters in Valkey through a Lua script, and Lua numbers are IEEE doubles — decimals there reintroduce the float errors this decision exists to prevent. One exact representation everywhere beats `numeric` in Postgres plus scaled integers in Valkey and a conversion boundary in the most concurrency-sensitive code in the system.
> **Catch weight is NOT a quantity** — it is a per-handling-unit actual weight (AD-22), so it never enters this rule.
> **Migration oracle:** replay-reconciliation (story 2.2) must reproduce every derived balance after the change.

**AD-18 — Storage conformance and segregation are enforced at the command layer `[PROPOSED]`**
> Every SKU and location carries a storage class and, where applicable, a hazard class, both from controlled vocabularies (DB CHECK, never free text). Putaway and pick refuse non-conforming placement and refuse co-location of segregation-incompatible goods. Conformance is a command rule, never a UI convention or a bin-naming habit. Excursions are ledger events, so chain of custody is reconstructible from the ledger alone.

**AD-19 — Product identity is two-level; the SKU stays the ledger's unit `[PROPOSED]`**
> `products` sits above `skus`; a SKU remains what every ledger event, reservation, pick and bin quantity references. Variants are an identity and presentation concern; no table below the catalog learns what a variant is. This is what keeps apparel and channel mapping additive.

**AD-20 — Reverse movements are registered ledger event types `[PROPOSED]`**
> Returns register their own grammar arms under AD-11 (`return.received`, `return.restocked`, `return.scrapped`). A return is never a sign-flipped receipt and never a reversal of the dispatch event — the dispatch happened, and the ledger is append-only.

**AD-21 — Fiscal and legal state gates movement `[PROPOSED]`**
> Customs status, excise status and controlled-substance status are **states on stock**, not parallel ledgers. Movements are gated on them, and each transition is an auditable event. One mechanism serves bonded, excise and controlled goods — three regimes, one model, so Tier 3 does not become three disconnected subsystems.

**AD-22 — Handling units carry identity, containers are assets `[PROPOSED]`**
> A handling unit (pallet, case, cylinder, keg) may carry its own identity, its actual weight (catch weight), and its own location. **Returnable containers are assets tracked distinctly from the stock they carry** — a cylinder's location and custody survive the gas being consumed.

**Deferred — add:**
> - **True `numeric` quantities** — considered and rejected for scaled integers at the AD-9 amendment; revisit only if a UoM ever needs more than 6 decimal places.
> - **Defence/classified handling** — clearance, classified segregation and government procurement; foundations reachable via AD-18/AD-21, not planned.

### 4.4 UX — **[Action-needed]**

Requires a `bmad-ux` pass before Tier 1 is specced: fractional quantity entry and display (precision per UoM, and never showing `18.400000`), catch-weight capture at receiving and pack, variant-aware catalog and pick surfaces, segregation and conformance refusals on the mobile scan path, returns end to end, container custody views, and register/status surfaces for Tier 3.

---

## 5. Implementation Handoff

**Scope: Major — PRD rewrite.** Beyond a Developer-agent change.

| Recipient | Responsibility |
|---|---|
| **Product Manager** (`bmad-agent-pm`) | PRD rewrite — vision, personas, non-users, FR-31…FR-74 |
| **Solution Architect** (`bmad-agent-architect`) | Ratify the AD-9 amendment and AD-18…AD-22; own the Tier 0 migration design |
| **UX Designer** (`bmad-agent-ux-designer`) | §4.4 pass, before Tier 1 specs |
| **PO / Developer** | `epics.md` entries, FR coverage map, dependency flow, `sprint-status.yaml` |
| **Developer** (`bmad-build`) | Story execution in tier order |

### Risk register

| Risk | Severity | Mitigation |
|---|---|---|
| Tier 0 migration corrupts derived quantities | **High** | Replay-reconciliation (2.2) is the oracle — every balance must reproduce; migrate before epic 5 while the surface is 4 epics, not 9 |
| Valkey/Lua precision loss | **High** | Scaled integers everywhere; no decimals ever reach Lua |
| Tier 3 statutory exposure | **High** | Own tier, built after foundations; registers are auditable events under AD-21 |
| Roadmap doubles in size (9 → 20 epics) | Medium | Tiers ship and sell independently; each tier is a release boundary, not a milestone |
| PRD rewrite stalls delivery | Medium | 4-2d and 4-6c are untouched and proceed in parallel |

### Success criteria

1. A grain depot books stock in tonnes to three decimals and a fishmonger records per-case catch weight — replay-reconciliation reproduces every balance after migration.
2. A frozen SKU cannot be put away into an ambient bin, and an oxidiser cannot be co-located with a fuel — enforced by command, proven by e2e.
3. An apparel seller models size×colour as variants **with no ledger schema change**.
4. A pharma distributor stocks a batch-and-serial SKU, picks it, and traces any serial to its lot.
5. A bonded pallet cannot be dispatched duty-unpaid, and the refusal is an auditable event.
6. Story 4-6d is unblocked and epic 4 closes.
7. **Outside Tier 0, no tier requires a ledger migration.** A story that needs one is wrong and returns here.

### Immediate next actions on approval

1. `sprint-status.yaml` — add epics 10–20 with tier comments; fix the stale `in-progress` on epics 1–3.
2. `epics.md` — eleven entries, FR coverage map, dependency flow.
3. Architecture spine — AD-9 amendment and AD-18…AD-22.
4. Route the PRD rewrite to PM and the UX pass to UX.
5. Commit as a meta docs PR (meta-last convention).
6. **Continue story execution with 4-2d**, which none of this touches.
