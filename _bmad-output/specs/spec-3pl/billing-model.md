# Billing model

Companion to `SPEC.md`. What a 3PL charges for, where each number comes from, and how an invoice is produced and defended.

## The governing rule

**Every charge traces to a ledger event.** Billing adds no new event types (AD-11 stays closed) and keeps no tally of its own (AD-25). Metering is aggregation over movements that already exist — which is why a disputed line can always be answered with "here are the events".

## Charge codes and their bases

| Charge code | Basis | One unit is | Metered from | Note |
|---|---|---|---|---|
| `storage` | `per_thousand_units_per_day` | 1,000 SKU base units held for a day | `storage_snapshots` (base milli-units ÷ 1,000,000) | The only charge needing **duration**, not events |
| `inbound_handling` | `per_receipt_line` | a distinct GRN line received | `grn.received` — **excluding** the re-emit on an over-receipt approval | Per line, not per unit — unloading cost scales with lines |
| `pick` | `per_pick` | a distinct picklist line picked | `pick.picked` — which the ledger emits once per batch arm or serial, so count lines, not events | The floor's unit of work |
| `outbound_handling` | `per_order` | a distinct order dispatched | `dispatch.dispatched` — emitted once per order **line**, so count orders, not events | Per shipment, independent of line count |

*(Amended by story 21-4 — what each charge is actually metered from: storage from `storage_snapshots`, one line per SKU base UoM, Σ daily closing base milli-units ÷ 1,000,000 × the rate; receipt lines from `goods_receipt_lines` by the GRN's `recorded_at` — every stored line, **including** one later rejected as an over-receipt; picks from `picks` rows (one per picklist line) by `created_at`; orders as distinct orders attributed to their FIRST `dispatch.dispatched` event (by its `recorded_at` and `client_id`) — an order whose lines ship either side of a boundary counts once. Each count has one predicate on the owning module's facade, which the dispute drill-down reuses. Transfers are not billed handling.)*

*(Amended by story 21-3: the event names are the ledger's real ones — there is no `order.dispatched` ledger event (that is the outbox event); each count is of distinct documents, not raw events. Storage is priced per 1,000 base units per day in whole paise, decision 1.)*

Both `charge_code` and `basis` are **closed vocabularies**, TS tuple plus migration CHECK, pinned together by an e2e test — the repo's pattern across its other ten enums.

**Why these four:** they are the charges every 3PL contract contains, and each maps to an event the ledger already records. A charge that needs new instrumentation is a charge this model is not yet ready for.

## Storage: the one that needs duration

The ledger records *movements*. Storage bills *presence over time*, which no single event carries.

A daily job writes one `storage_snapshots` row per (client, warehouse, IST day, base UoM): the base milli-units on hand at the **end** of the IST day — the ledger fold over every event recorded before the IST midnight that ends it. A month's storage charge is then the sum of the daily values × the rate, per base UoM, each day priced by the card in force at its start.

**Stock leaves storage when it is picked** *(story 21-4, decision 2)*. The ledger takes picked stock out of its bin (a draw); packing and dispatch move nothing. So stock received on the 10th, picked on the 18th and dispatched on the 20th is stored the 10th through the 17th. Counting to dispatch would need a second fold over picks and dispatches, and would be harder to defend on a disputed invoice.

**A day is written only when it is complete** *(21-4)*: 15 minutes past its IST midnight **and** once no transaction that began before that midnight is still open (`pg_stat_activity` — the same proof covers the handling counts; `modules/billing.md`). A drift check (a recent-days re-fold plus a genesis-sum check) runs once per IST day per scope and logs any mismatch; a verify/rebuild script re-derives the whole projection.

**This is a projection, not a book.** Replaying the ledger must reproduce every snapshot exactly, and a rebuild is the test (AD-25). It is a cache for a number that is otherwise expensive to compute, and it is how 3PL contracts are written anyway — in storage *days*.

**What "billable units" counts** was the first open question in `SPEC.md`. **Settled by story 21-3 (decision 1): SKU base units, priced per 1,000 per day.** Pallet or bin storage waits for a real pallet concept — 10-3's handling units are catch-weight cases with no location, client or ledger events, so there is nothing to count (`docs/design/PENDING.md` §billing). Unlike base units are never summed: **story 21-4 counts each base UoM separately** — one snapshot row and one storage line per unit, each priced at the card's storage rate (21-4 decision 1).

## Rate cards

Versioned by effective date, never edited in place. A rate change writes a **new card** and closes the old one.

**Why versioning is load-bearing:** an invoice issued in March, re-rendered in June after an April rate change, must still show March's numbers. Recording `rate_card_id` **on each invoice line** — rather than looking up the live card — is what makes that true, and it is why CAP-4's success criterion is "the previous month's issued invoice stays byte-identical". A card may take effect on any date, so a period spanning a change splits each affected line in two (story 21-3, decision 5).

**The lifecycle** (story 21-3, `docs/design/modules/billing.md`): `draft` (editable, undated) → `active` from an IST-midnight date (frozen by database triggers) → `superseded` when a later card takes over from its own date. A card whose date has not arrived can be `cancelled` — never in force — which reopens the card it superseded. A first card may start today (IST); a replacement starts tomorrow at the earliest. Owner and accountant edit (`rates.manage`); every member reads.

**Flat rates only.** Tiered pricing (first 100 pallets at X, above at Y) is a stated non-goal: it multiplies the calculation surface, and every tier boundary becomes a dispute.

## Invoice lifecycle

```
draft ──issue──> issued ──> settled
                    │
                    ├──> disputed ──> settled
                    └──> void
```

- **`draft`** — computed, reviewable, recomputable. Nothing is promised.
- **`issued`** — **immutable.** `issued_at` is stamped, amounts are frozen. A correction is a new document, never a mutation of a sent one.
- **`disputed`** — the client contests it; the line's source events are what answers the dispute.
- **`void`** — issued in error, superseded by a replacement that names it.

*(Amended by story 21-5 — as built:)* the moves are `issued → disputed | settled | void` and **`disputed → settled | void`** (a dispute that ends in a correction voids the invoice; the diagram above omitted `disputed → void`). Dispute and void need a note; a void keeps its number and the next prepare of its month and GSTIN drafts a replacement naming it (`replaces_invoice_id`). **Drafts are hidden from the portal** — the RLS client clause shows a client only its non-draft invoices. Issue re-meters first: if the figures moved since the draft was computed, the fresh draft is stored and the answer is `stale` — nothing issued, no number spent. Billing ignores the client's status (a suspended client still owes for what it used).

The immutability rule is the whole reason the model records its inputs rather than referencing them live.

## GST: services, not goods

**Epic 8's invoicing path does not apply here.** It is built for selling goods: HSN codes, goods GST treatment, e-way bills for movement. A 3PL sells a **service** — storage and handling — which carries **SAC codes** and different GST treatment, and generates no e-way bill because nothing of the 3PL's is moving.

Shared machinery (GST rates as basis points, integer paise, the invoice numbering discipline), separate code path. *(Amended by story 21-5:)* the shared machinery is `shared/primitives/gst.ts` (`computeLineTax`, `roundToRupee`, `fyLabelFor`, and `formatServiceInvoiceNo` — `29/S2627/000001`, its own series per supplying GSTIN per FY). One invoice per client per month **per supplying GSTIN** (each registration invoices the work done in its warehouses); SAC `996729` storage and `996719` handling at 18 % (decision 4); place of supply = the client's state under IGST Act s.12(2), stored per line (decision 5 — the s.12(3) storage question is a CA check in PENDING). `client_invoice_lines.sac_code` exists for exactly this reason, and it is the clearest signal that client billing is not a variant of order invoicing.

## Two billing relationships, deliberately not conflated

| | Who bills whom | Status |
|---|---|---|
| **Client billing** | The 3PL bills its client brands for storage and handling | **This spec** |
| **Subscription billing** | The product bills the tenant for using it | **Not covered by any epic**, and PRD open question 4 on the pricing axis is still unresolved |

They share no tables and no code. Naming both here so the second is not mistaken for solved: the product still cannot charge anyone for itself.

## What a dispute looks like

A client challenges March's `pick` line. An operator opens the invoice line, which names its charge code, basis, quantity and the rate card in force, and expands to the `pick.picked` events that produced the count — each carrying its own actor, timestamp, order and SKU.

That flow is the reason for every architectural choice above: the ledger as the single source, the rate card recorded rather than referenced, and the invoice frozen at issue. Billing a client is easy; **defending the bill** is the requirement.
