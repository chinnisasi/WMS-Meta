# Billing model

Companion to `SPEC.md`. What a 3PL charges for, where each number comes from, and how an invoice is produced and defended.

## The governing rule

**Every charge traces to a ledger event.** Billing adds no new event types (AD-11 stays closed) and keeps no tally of its own (AD-25). Metering is aggregation over movements that already exist — which is why a disputed line can always be answered with "here are the events".

## Charge codes and their bases

| Charge code | Basis | Metered from | Note |
|---|---|---|---|
| `storage` | `per_unit_per_day` | `storage_snapshots` | The only charge needing **duration**, not events |
| `inbound_handling` | `per_receipt_line` | `grn.received` | Per line, not per unit — unloading cost scales with lines |
| `pick` | `per_pick` | `pick.picked` | The floor's unit of work |
| `outbound_handling` | `per_order` | `order.dispatched` | Per shipment, independent of line count |

Both `charge_code` and `basis` are **closed vocabularies**, TS tuple plus migration CHECK, pinned together by an e2e test — the repo's pattern across its other ten enums.

**Why these four:** they are the charges every 3PL contract contains, and each maps to an event the ledger already records. A charge that needs new instrumentation is a charge this model is not yet ready for.

## Storage: the one that needs duration

The ledger records *movements*. Storage bills *presence over time*, which no single event carries.

A daily job writes one `storage_snapshots` row per (client, warehouse, day): the billable units held at the snapshot instant. A month's storage charge is then the sum of daily billable units × the rate.

**This is a projection, not a book.** Replaying the ledger must reproduce every snapshot exactly, and a rebuild is the test (AD-25). It is a cache for a number that is otherwise expensive to compute, and it is how 3PL contracts are written anyway — in storage *days*.

**What "billable units" counts** is the first open question in `SPEC.md`: units, pallets, bins or volume. The rate card can express any of them; the onboarding flow has to propose one. Once story 10-3 lands handling units, per-pallet becomes the natural default, because a pallet is the thing a 3PL actually rents space to.

## Rate cards

Versioned by effective date, never edited in place. A rate change writes a **new card** and closes the old one.

**Why versioning is load-bearing:** an invoice issued in March, re-rendered in June after an April rate change, must still show March's numbers. Recording `rate_card_id` **on the invoice** — rather than looking up the live card — is what makes that true, and it is why CAP-4's success criterion is "the previous month's issued invoice stays byte-identical".

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

The immutability rule is the whole reason the model records its inputs rather than referencing them live.

## GST: services, not goods

**Epic 8's invoicing path does not apply here.** It is built for selling goods: HSN codes, goods GST treatment, e-way bills for movement. A 3PL sells a **service** — storage and handling — which carries **SAC codes** and different GST treatment, and generates no e-way bill because nothing of the 3PL's is moving.

Shared machinery (GST rates as basis points, integer paise, the invoice numbering discipline), separate code path. `client_invoice_lines.sac_code` exists for exactly this reason, and it is the clearest signal that client billing is not a variant of order invoicing.

## Two billing relationships, deliberately not conflated

| | Who bills whom | Status |
|---|---|---|
| **Client billing** | The 3PL bills its client brands for storage and handling | **This spec** |
| **Subscription billing** | The product bills the tenant for using it | **Not covered by any epic**, and PRD open question 4 on the pricing axis is still unresolved |

They share no tables and no code. Naming both here so the second is not mistaken for solved: the product still cannot charge anyone for itself.

## What a dispute looks like

A client challenges March's `pick` line. An operator opens the invoice line, which names its charge code, basis, quantity and the rate card in force, and expands to the `pick.picked` events that produced the count — each carrying its own actor, timestamp, order and SKU.

That flow is the reason for every architectural choice above: the ledger as the single source, the rate card recorded rather than referenced, and the invoice frozen at issue. Billing a client is easy; **defending the bill** is the requirement.
