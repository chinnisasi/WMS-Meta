# System design (high level)

How the pieces fit. Decisions and their rationale live in `ARCHITECTURE-SPINE.md` (AD-1…AD-25); this describes the shape those decisions produced.

Companions: `IMPLEMENTATION-GUIDE.md` (the patterns to code by), `../repos/wms-be/README.md` (the API contract).

---

## Three repositories

| Repo | What it is | Who uses it |
|---|---|---|
| **wms-be** | NestJS + Drizzle + Postgres + Valkey. Owns all state and all rules | everything |
| **wms-fe** | Next.js + shadcn/ui. Web dashboard | Owner, Ops Manager, Accountant |
| **wms-mobile** | Expo/RN. Offline-first scan client | Operators on the floor |

Both clients consume a **generated** API client — no hand-written request types (AD-8). The backend is the only thing that decides anything.

---

## The one idea the system is built on

**The ledger is the only stock truth** (AD-1). Nothing anywhere mutates a quantity directly. Every movement is an append-only `ledger_events` row, and `stock_on_hand` / `batch_on_hand` are **projections** folded forward from it.

That single decision produces most of the architecture:

- **Corrections are new events**, never edits — so history is complete by construction
- **A projection can be rebuilt** by replaying the ledger, which makes it a cache rather than a second source of truth
- **Divergence is detectable**: a background job continuously replays and compares, and quarantines what disagrees (story 2.2)
- **Anything derived is derived the same way** — registers (AD-21), billing (AD-25), reporting. Nothing keeps a parallel book

When something new needs to be counted, the first question is "which existing ledger events say this?" — usually the answer is all of them.

---

## Request lifecycle

```
HTTP → Controller (api shell)  ── thin: auth guard, tenant match, DTO validation, idempotency header
         ↓
     Facade (AD-6 seam)         ── the ONLY thing a sibling module may import
         ↓
     Command service (AD-10)    ── the whole transaction: authority, replay, lock, guard, write,
         ↓                         outbox, audit, idempotency key
     Postgres (RLS behind it)   ── tenant_id on every row; RLS is defence in depth, not the gate
         ↓
     post-commit                ── Valkey counter mirrors, never throwing
```

**Controllers are deliberately thin** — they map DTOs and read the idempotency header. The intent is that they hold no rules; it is not uniformly true. `catalog/import.command.ts:152-155` parses the uploaded file *before* the `catalog.import` check at `:170`, which inverts authority-before-validation (`PENDING.md`, verified finding 2). Treat "thin" as the rule to code to, not a property you may assume when reading. Story 10.2 moved quantity conversion *out* of controllers into commands, because anything in front of the command runs before the replay lookup — and a refusal in front of a replay answers 400 to an op that already committed.

---

## Modules (AD-6)

Thirteen modules, each owning its tables exclusively. **Siblings communicate only through a facade or an event — never by touching another module's tables.** The 3PL client dimension (Epic 21, story 21-1) adds the fourteenth: `clients`. Its table is written only inside the module — registration reaches it through `ensureSelfClientInTx`, and since 21-2b the owner's admin commands create and rename clients. The other modules never write it: they **read** it through `clients.facade.ts`, and documents and ledger rows **derive** their `client_id` from their SKUs (`assertSingleClientInTx`) rather than stamping `self` (`modules/clients.md`). Story 21-3 adds the fifteenth, `billing`: it owns the rate-card tables, reads (and locks) the client row only through `clients.facade.ts`, and writes no stock (`modules/billing.md`).

`test/architecture.spec.ts` scans source for writes and past-the-facade imports, but **it covers ten module table-sets, not fifteen**: stock/ledger (inventory), order/wave/pick (outbound), catalog identity (10.3 — batches, serials, handling units; not the SKU table itself), carriers, clients (21-1), transfers (movements), replenishment, channels, invoices (invoicing) and rate cards (21-3 billing: only billing writes or even reads `rate_cards`/`rate_card_lines`, it writes no stock/client/order table, siblings import only its facade) — plus the `int4` guard, the 7-2 ingest/writeback seams and the 9-1 reporting block (reporting writes nothing and only the api shell imports it). **`tenancy`, `inbound`, `putaway` and `compliance` table ownership is unenforced** (and the `skus` table only partly — its client column has its own 21-2b guard), and `bins` — the one table deliberately shared by column between tenancy and putaway — is the least-guarded case of all. Adding a module block when you add a module is the standing rule; the unenforced ones predate it.

| Module | Owns |
|---|---|
| `tenancy` | tenants, users, roles, warehouses, zones, bins, devices |
| `clients` | the client dimension (AD-23): the `self` client per tenant, `client_id` on `skus`/`orders`/`purchase_orders`/`ledger_events` — 21-1 |
| `catalog` | SKUs, batches, serials, UoM vocabulary |
| `inventory` | **the ledger**, projections, reservations, ATP, reconciliation |
| `inbound` | purchase orders, receiving, GRNs, QC holds |
| `putaway` | directed putaway, bin administration |
| `outbound` | orders, waves, picklists, picks, pack, dispatch |
| `carriers` | carrier registry, tenant credential vault |
| `compliance` | temperature excursions (FR-44): record → per-scope QC holds + zero-delta ledger events, resolve (the review flip) — 12-5 |
| `movements` | counts, variances, stock adjustments' review, moves/transfer orders (epics 5, 15+) |
| `replenishment` | the stock-intelligence spine (epic 6): the breach sweep + suggested-PO drafts (6-1, FR-22) and the expiry/aging batch-alert scan on the SAME tick (6-2, FR-23) — alerts are evidence; only a human submit orders |
| `channels` | sales-channel connections, standing buffers, availability sync (7-1), webhook ingest + fulfillment writeback (7-2) |
| `invoicing` | GST invoices (8-1): one per dispatched order, derived from dispatch facts over `order.dispatched`, exact paise/bps math, per-tenant FY numbering (per supplier GSTIN since 8-1b); the HSN summary shipped in 8-2a — a read model over issued invoices (`issued_at`, `invoice_lines.uom`) with one catalog read, via `CatalogFacade`, for the current-HSN hint; e-way bills (8-2b) queue off `invoice.issued`, export as NIC bulk JSON or generate through the `EwayGateway` port (unconfigured in production) |
| `reporting` | the operational dashboard (9-1, FR-27): a read model with **no tables** — ten per-warehouse KPI tiles computed live over the owning modules' records (the ONE named read-only exception to the facade rule, decision 6 — `IMPLEMENTATION-GUIDE.md` §7a), each figure carrying the list route behind it. The audit trail and exports (9-3) join it next |
| `billing` | client billing (AD-25), story 21-3: **rate cards** — a client brand's versioned prices (`rate_cards`, `rate_card_lines`), drafted then activated from an IST-midnight date and frozen after (DB triggers); a later card supersedes from its own date, a scheduled one can be cancelled (reopening its predecessor). The facade answers "in force at an instant" and "which cards cover a period" (segments — 21-5's invoice-line input). Story 21-4 adds **metering** (a client's usage per card segment, priced — the `usage` read) and the **daily storage snapshots** (`storage_snapshots`, a projection folded from the ledger under a commit guarantee), reading the ledger, GRN lines and picks only through the inventory, inbound and outbound facades. Client invoices (21-5) join it; it writes no stock |
| `notifications` | spine placeholder for epic 9 (9-2) |

The api shell (`src/api/`) is where two modules' reads are joined — the device catalog snapshot composes across `inbound` and `outbound` there rather than making one module import the other.

---

## Inventory: the core

**Reservations** (AD-12) are durable records with a lifecycle `held → committed → released/expired`, plus a TTL and a reaper. ATP is always read net of live reservations, which is what makes oversell protection real rather than advisory.

**The decision point is split, deliberately.** Postgres is the truth; Valkey holds a counter mirror for the hot path. A grant runs a Lua script against the counter, then journals in Postgres. The counter can drift; the journal cannot. A parity pass reconciles them, and **failure is always fail-closed** — a missing counter refuses the grant rather than granting blind.

**Quantities** are scaled integers in milli-units (AD-9 as amended, story 10.1), with each UoM declaring its precision (10.2). No decimals exist below the HTTP edge.

---

## Offline: the floor's constraint

The mobile client is offline-first (AD-4). Scan decisions run **on-device**; only persistence waits for the network.

- Ops queue FIFO and replay idempotently, exactly once
- Replay re-authorises against **the badge-in session that created the op** — shared devices never launder authority
- A queued op the server later rejects surfaces as a **retraction** in the sync summary, never a silent correction
- The scan banner has exactly four states, and **"Recorded · queued" is never shown as green-accepted** — the UI does not claim server truth it does not have

This is why the catalog snapshot exists: the device carries enough to decide locally (bins, SKUs, UoM precision, tasks). Anything the device must refuse in under 500 ms has to be in that snapshot.

---

## Integration: the outbox

Every integration crossing goes through a transactional outbox (AD-7). The state change and the event commit in **one** Postgres transaction; a relay drains them with a 5-attempt budget, exponential backoff and quarantine past budget.

So a carrier API being down never rolls back a dispatch. Domain state lands first; the integration catches up.

---

## Background work

| Job | Does |
|---|---|
| Outbox relay | drains integration events, backs off, quarantines |
| Reconciliation | replays the ledger, compares to projections, quarantines divergence |
| Reservation reaper | expires TTL'd holds, runs the counter parity pass |
| Storage snapshots (21-4) | writes each client brand's daily closing stock per warehouse and base UoM, once the day is provably complete; drift-checks the last 7 days (`STORAGE_SNAPSHOT_POLL_MS`) |

All poll on configurable intervals and **take explicit tenant context** — AD-3's scoping covers background work too, not just the API.

**They are sheddable** (AD-17): under load they yield to the scan path and order acceptance. The floor scanning is the thing that must never slow down.

---

## Where state lives

| | |
|---|---|
| **Postgres** | everything durable. 40 tables, 28 migrations. RLS on every one |
| **Valkey** | ATP counters only — a rebuildable mirror, never a source of truth |
| **Device cache** | encrypted catalog snapshot + the outbound op queue |

---

## Testing shape

27 e2e suites, each on its own cloned database, driving **real HTTP** against a real Nest app. Plus `architecture.spec.ts`, a static scan that fails when the design erodes rather than when the code breaks — over the four blocks it actually covers (see Modules above).
