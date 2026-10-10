---
id: SPEC-3pl
companions:
  - architecture.md
  - schema.md
  - billing-model.md
  - architecture-diagrams.md
sources: []
---

> **Canonical contract.** This SPEC and the files in `companions:` are the complete, preservation-validated contract for what to build, test, and validate. Source documents listed in frontmatter are for traceability — consult them only if you need narrative rationale or prose color this contract intentionally omits.

# 3PL — storing and shipping other companies' goods, and billing for it

## Why

**An opportunity to capture, and a mis-scoped product to correct.** A 3PL stores and ships goods it does not own, for many client brands at once, out of one building — and bills each client for the storage and the handling. That is a different business from the D2C seller the PRD was written for, and it is the one where warehouse software is bought rather than tolerated: a 3PL's software *is* its operation, and its invoice is its revenue.

The product already does the hard part. Receiving, putaway, scan-verified picking through dead zones, packing, dispatch and an append-only ledger all work, and they work the same whoever owns the goods. What is missing is the dimension that says **whose** goods these are, and the billing that dimension makes possible.

The PRD currently forecloses this: §2.2 lists 3PLs under Non-Users as "a v2 wedge, not v1", §443 says "No 3PL multi-client billing in v1", §471 files it as a v2 candidate. Zero of the twenty epics cover it. That framing is now wrong — 3PL is core product alongside D2C, and the two share one model rather than branching.

**Why now rather than later:** the client dimension is migration-shaped. Every epic built without it is an epic that has to be revisited, exactly as the quantity model was in story 10.1. It is cheapest today and never cheaper again.

## Capabilities

- **CAP-1 — Client as a first-class entity**
  - **intent:** A tenant can register the client brands whose goods it holds, and every unit of stock, every order and every inbound document is attributable to exactly one of them.
  - **success:** A 3PL tenant with two clients holds stock for both in the same warehouse and the same bins; each unit's owner is answerable from the ledger alone.

- **CAP-2 — Client isolation that cannot leak**
  - **intent:** A client can never see, reserve or draw another client's units, no matter which surface or query reaches for them.
  - **success:** A client-portal session issued for client A returns zero rows for every one of client B's SKUs, orders, batches and ledger events — proven by a database-level probe, not only by an API test.

- **CAP-3 — D2C is the one-client case**
  - **intent:** A tenant that owns its own goods uses the identical model with a single system-owned client, so no surface, query or command branches on "3PL mode".
  - **success:** Every existing D2C flow behaves identically after the client dimension lands, with no conditional client logic anywhere in the command layer.
  - *(Amended 2026-10-10 (epic-21 retro, as built): the code **does** branch on `clients.system_owned` — not on a "3PL mode", but on the `self` client — to refuse billing and invoicing work for it. 21-2b decision 5: GST invoicing skips a client brand's order (409 `client-order-not-invoiced`, `invoicing/generator.ts`), so only `self` orders get a tax invoice. Billing refuses the `self` client: no rate card (`rate-card.command.ts` `assertPricedClient`), no client invoice (409 `client-not-billable`, `client-invoices.ts` `assertBillableClient`), no storage snapshot or storage metering (`storage-snapshot.ts`, `metering.ts`, 21-4 decision 4). `self` is also never renamed and gets no portal users. D2C flows are otherwise unchanged.)*

- **CAP-4 — Rate cards per client**
  - **intent:** An operator can define what a client is charged and from when, covering storage per unit per day and handling per receipt line, per pick and per order.
  - **success:** A rate change effective the 1st leaves the previous month's issued invoice byte-identical.
  - *(Amended 2026-10-10 (epic-21 retro, as built): storage is priced **per 1,000 base units per day** (basis `per_thousand_units_per_day`, whole paise), one line per SKU base UoM — not per unit and not per pallet. Pallet and bin storage wait for a real pallet concept (21-3 decision 1; 21-4 decision 1; `billing-model.md`).)*

- **CAP-5 — Charges metered from the ledger**
  - **intent:** Every billable event is derived from movements already recorded, not from a separately maintained tally.
  - **success:** Deleting and recomputing a billing period's charges reproduces them exactly from the ledger and the rate card in force.

- **CAP-6 — Storage measured in duration**
  - **intent:** A client is charged for how long its goods occupied space, not merely for what moved.
  - **success:** Stock received on the 10th and dispatched on the 20th bills the storage days the rate card defines, and the count is reproducible from the ledger.
  - *(Amended 2026-10-10 (epic-21 retro, as built): storage **stops at the pick, not at dispatch** — picking draws the stock out of its bin, while pack and dispatch move nothing in the ledger. Stock received on the 10th and picked on the 18th is stored the 10th through the 17th (21-4 decision 2, `storage-snapshot.ts`). The unit is per 1,000 base units per day (CAP-4 note).)*

- **CAP-7 — Client invoices**
  - **intent:** An operator can issue a period invoice to a client, and both sides can see which events produced each line.
  - **success:** Every invoice line traces to the ledger events that generated it; an issued invoice never changes when upstream rates or data change.
  - *(Amended 2026-10-10 (epic-21 retro, as built): the lifecycle gained **`disputed → void`** — `issued → disputed | settled | void` and `disputed → settled | void`. A dispute that ends in a correction voids the invoice, and the next prepare drafts a replacement naming it (21-5; `billing-model.md`).)*

- **CAP-8 — Client portal**
  - **intent:** A client can see its own stock, orders, inbound and invoices without an operator relaying it.
  - **success:** A client user signs in and completes a stock enquiry and an invoice review touching no operator-only surface and no other client's data.

- **CAP-9 — Advance shipment notices**
  - **intent:** A client can announce an inbound shipment before it arrives, and receiving can book against it exactly as it books against a purchase order.
  - **success:** A GRN references an ASN and reconciles announced against received quantities with the same partial, blind and over-receipt handling a PO gets.

- **CAP-10 — Per-client service reporting**
  - **intent:** An operator and a client can both see how the operation performed for that client — dock-to-stock, pick accuracy, dispatch timeliness.
  - **success:** Each figure is computed per client from the ledger and reconciles to it, with no separately maintained metric store.
  - *(Amended 2026-10-10 (epic-21 retro, as built): only the **dispatch-derived** figures read the ledger. Timeliness and the accuracy denominator come from `dispatch.dispatched`, and `ordersDispatched` equals the invoiced dispatched-order count (pinned by `test/service-report.spec.ts`). Dock-to-stock and short picks are projections over rows written in the same transaction as their ledger events. Pack failures come from a fact table (`pack_verification_failures`, not backfilled before 0058). See 21-8 Design Notes.)*

## Constraints

- **Client is `NOT NULL` wherever it appears, with one system-owned "self" client per tenant.** A nullable scoping column is where isolation bugs live — every query would have to remember `OR client_id IS NULL`, and the one that forgets is the leak.
- **Tenant-level RLS does not give client isolation.** AD-3 scopes `tenant_id` + `warehouse_id`; clients share a tenant. Portal isolation needs its own enforcement — see `architecture.md`.
- **Billing is a projection over the ledger, never a parallel book.** The same rule AD-21 applies to statutory registers. A charge nobody can trace to a movement is not a charge.
- **An issued invoice is immutable.** Rate changes, corrections and late data produce a new document, never a mutation of a sent one.
- **Cross-client operations must stay possible.** A wave may span clients, because picking one route for two clients is most of a 3PL's efficiency. Isolation is about visibility and ownership, not about partitioning the floor.
- **A 3PL invoices services, not goods.** Epic 8's GST path is built for HSN-coded goods; client billing is SAC-coded services with different GST treatment. Shared machinery, separate code path.
- **The client dimension lands before the epics that would inherit it.** Phase 0, beside epics 10 and 11 — it is migration-shaped and only gets more expensive.

## Non-goals

- **Tiered and volumetric pricing.** Flat rates only. Tiers multiply the calculation surface and every dispute argument with it.
- **Payment collection, dunning, credit control.** The product issues invoices; it does not take money or chase it.
- **Client-initiated order entry.** The portal is read-mostly plus ASN. Clients placing outbound orders directly is its own trust and validation surface.
- **Per-client physical partitioning of the warehouse.** Commingled by default; dedicated storage is a bin attribute, not a separate inventory space.
- **EDI.** Already a v2+ item in the PRD and unchanged by this spec.
- **Multi-currency.** Integer paise, as everywhere else in the product.
- **Retrofitting historical D2C data into multiple clients.** Existing tenants get one self client and nothing moves.

## Success signal

A 3PL onboards two client brands into one warehouse, receives an ASN-announced shipment for each, picks a single wave that spans both, dispatches, and at month end issues each client an invoice whose every line traces back to the ledger events that produced it — while each client, signed into the portal, can see their own stock and invoice and is provably unable to see the other's.

## Assumptions

- Commingled storage is the default and dedicated storage is a bin attribute (`bins.dedicated_client_id`), because most 3PLs commingle and segregate only by contract exception — and Epic 12's storage classes already provide the segregation machinery.
- Storage is billed in whole days from a daily snapshot, the way 3PL contracts are normally written, rather than by continuous occupancy integration.
- One tenant is one 3PL operator. A client belongs to exactly one tenant; a brand using two 3PLs is two unrelated client records.

## Open Questions

*(Amended 2026-10-10 (epic-21 retro): three of the four are settled, by the story named on each. Client departure stays open.)*

- ~~Which charge basis does storage use by default — per pallet, per bin, per cubic metre, or per unit? The rate card can express several, but one has to be the default the onboarding flow proposes.~~ **Settled by 21-3 decision 1:** per 1,000 base units per day, the only storage basis. Pallet and bin storage wait for a real pallet concept (PENDING billing).
- ~~Does a client user need to see *cost* (their rate card) in the portal, or only their invoices? Exposing rates makes disputes self-service and makes renegotiation pressure constant.~~ **Settled by 21-7 decision 3:** invoices and their lines only. The rate card and the line drill-down stay operator-side. "Portal visibility of rate cards" stays in PENDING billing.
- When a client leaves, what happens to their ledger history — retained under the tenant for audit, exported and purged, or transferred? This interacts with AD-16's retention architecture and with whatever the contract says. **Still open** — PENDING clients, "Client status transitions and departure".
- ~~Is a client permitted to hold stock across more than one of the tenant's warehouses under one client record, or is a client record per warehouse?~~ **Settled by 21-2b (design review #13):** one tenant-wide client record may hold stock in several warehouses. Attribution is per SKU, and SKUs are tenant-wide (PENDING clients).
