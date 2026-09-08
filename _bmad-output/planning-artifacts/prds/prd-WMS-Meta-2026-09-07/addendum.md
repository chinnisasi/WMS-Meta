# Addendum — WMS PRD

Depth that belongs downstream (architecture, solution design) or earned a place but didn't fit the PRD. Captured during Discovery, 2026-09-07.

## 1. Technical mechanisms (for `bmad-architecture`)

### 1.1 Inventory ledger + derived projections (FR-4, FR-5, NFR-1)

The scalability research was unambiguous: mutable "current quantity" tables are the classic WMS failure — unauditable, unreplayable, and the root of both oversells and unexplainable variances.

- **Append-only ledger**: every stock movement (receipt, putaway, pick, pack, dispatch, transfer leg, adjustment, count variance) is an immutable event: `(event_id, tenant_id, warehouse_id, type, sku, batch/serial, from_bin, to_bin, qty, actor, timestamp, reference_doc, idempotency_key)`.
- **Derived projections** for on-hand, ATP, and dashboard KPIs; snapshots/checkpoints avoid full-replay cost.
- **Atomic reservation** must keep the relational DB out of the hot path for check-and-decrement — the flash-sale failure mode is row-lock queuing on exactly the inventory rows being sold. In-memory or single-writer ATP state with sub-10ms decisions, event stream to persistence. (Case studies: Flink/Kafka retail deployments; OneStock OMS failure analysis.)
- **Idempotency keys on every write** — non-negotiable given offline mobile queueing (NFR-3) and channel webhooks.

### 1.2 Tenancy (NFR-4)

- Shared schema, `tenant_id` on every table and every access path; config-as-metadata (per-tenant workflows/order types/label logic in metadata tables, never code).
- **Warehouse as first-class partition key from day one**, even for single-warehouse tenants — retrofits are brutal and warehouse-count is the expected expansion axis (Zoho monetizes it directly).
- Defer: per-tenant databases, noisy-neighbor compute isolation beyond load-shedding priority (scanning > background sync).

### 1.3 Offline mobile sync (FR-14, NFR-3)

- Local store (SQLite/IndexedDB, WAL) + outbox FIFO queue + ULID idempotency keys; replay on reconnect in task order; LWW conflicts escalate to human review rather than silent resolution.
- Scan decision logic (accept/reject, FEFO, wrong-bin) runs **on-device** so dead zones don't stop the floor — only ledger persistence waits for network.

### 1.4 What to defer (architecture-level)

Modular monolith with clean event seams is fine for v1 — no microservice sprawl, no multi-region pinning, no CRDTs/vector clocks, no 2PC across services, no RFID edge services (keyboard-wedge HID + the scan-event abstraction covers the barcode era). Load-test at 10–15× baseline before peak season (NFR-2).

## 2. Integration surface (for architecture + partnerships)

Ranked by observed vendor investment across comparables:

1. **E-commerce platforms** — Shopify deepest in the industry (ShipHero/Logiwa are Shopify Plus certified); Amazon.in, Flipkart for India launch. Official seller APIs have partner-approval lead times — launch-plan risk tracked as Open Question 2.
2. **Accounting** — Tally + Zoho Books are the India anchors (Zoho's own pairing; Fishbowl grew on QuickBooks equivalently). v2.
3. **Carriers** — India v1 set (Delhivery, Blue Dart, Ecom Express, Shiprocket as aggregator breadth); rate-shopping + multi-carrier labels are table stakes.
4. **Oversell protection pattern** (converged industry-wide): per-channel safety buffers + atomic stock locks + near-real-time availability sync.
5. **EDI/3PL (SPS Commerce class)** — enterprise wedge, deferred.

## 3. Pricing benchmark (Zoho Inventory, India annual — for Open Question 4)

| Tier | Orders/mo | Users | Warehouses | Notable gates |
|---|---|---|---|---|
| Free | 50 total | 1 | 1 | dropshipping, backorders included |
| Standard ₹999 | 500 | 3 | 2 | — |
| Premium ₹2,299 | 3,000 | 5 | 4 | **serial+batch, barcode, counts, UoM, automation** |
| Plus ₹4,999 | 7,500 | — | 6 | + Commerce bundle |
| Enterprise ₹7,499 | 15,000 | 10 | 10 | Analytics, multi-currency |

Signals: warehouse count is a metered expansion axis (add-on ₹600/warehouse/mo); "Advanced warehousing" add-on ₹4,166/org/mo; traceability is Premium+ — our PRD includes batch tracking in v1 as a deliberate wedge against that gating.

## 4. Research digests (archived)

Full digests from the three Discovery research agents (2026-09-07): Zoho Inventory feature/integration survey; best-in-class WMS feature survey (Gartner MQ 2025 summaries, Zebra, Körber, ShipHero, Logiwa, practitioner sources); WMS scalability-pattern survey (JD Economics BFCM, Ksolves Flink case study, OneStock, Shopify/Airbnb ledger talks, offline-sync patterns). Digests were delivered in-session and are condensed into §§1–3 above; ask the PM for the verbatim transcripts if needed.

## 5. Deferred alternatives and rationale

- **Serial tracking in v1** — differentiator vs Zoho's Premium gate, but adds catalog + picking surface; defers before batch tracking under pressure (Assumption §4.2, Open Question 5).
- **3PL-first wedge** — highest differentiation (multi-client billing), hardest v1; tenancy design keeps it reachable. Chosen segment: SMB e-comm sellers.
- **US/global-first** — rejected: the reference product and seller context are India-anchored; GST/e-way nativity is a positioning asset, not a compliance tax.
- **Web-only v1** — rejected: floor scanning is the product's core claim (SM-2); a dead-zone-tolerant mobile client is load-bearing, not accessory.