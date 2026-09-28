# Epic 21 Context: 3PL — Clients, Billing & Client Portal

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Turn the WMS into a system that can run as a 3PL: it stores and ships *other companies'* goods out of one building, and bills each client for it. Clients become a scoping dimension inside the tenant (a third dimension beside `tenant_id`/`warehouse_id`), so stock, orders and inbound documents are attributable to exactly one client; isolation is enforced by the database so a client can never see another's rows; billing meters charges from ledger events that already exist; and clients get a read-mostly portal and per-client service reporting. D2C is deliberately the one-client case of this model — a system-owned `self` client per tenant — so no command, query or surface branches on "3PL mode". The client dimension is migration-shaped (NOT NULL columns + backfill on core tables), so the migration pair lands in Phase 0 beside Epic 10 and every later epic inherits it born client-ready.

**Design source:** the ratified 3PL design lives in `_bmad-output/specs/spec-3pl/` (SPEC, schema, billing-model, architecture, architecture-diagrams) — the planning-era architecture/PRD/UX docs predate it and only carry dated amendment notes. Story specs must list the spec directory in their `context:` frontmatter; the spine decisions AD-23/24/25 are its ratified summary.

## Stories

- Story 21.1: Client dimension migration — `clients` table, system-owned `self` client, `client_id` on core tables + backfill (migration A, Phase 0)
- Story 21.2: Client isolation — second RLS session variable `app.client_id`, fail-closed policies, DB-level isolation probe (Phase 0)
- Story 21.3: Rate cards — versioned, closed `charge_code`/`basis` vocabularies
- Story 21.4: Metering + daily storage snapshot job (rebuildable projection)
- Story 21.5: Client invoices — draft→issued immutable, SAC services GST, dispute traceability
- Story 21.6: Advance shipment notices — ASN document beside the PO; GRN books against PO-or-ASN
- Story 21.7: Client portal — read-mostly (stock, orders, inbound, invoices) under `app.client_id` sessions
- Story 21.8: Per-client service reporting — dock-to-stock, pick accuracy, dispatch timeliness from the ledger

## Requirements & Constraints

- **Client as first-class entity.** Every unit of stock, order and inbound document is attributable to exactly one client; ownership is answerable from the ledger alone.
- **Isolation that cannot leak, proven at the database.** A portal session for client A must return zero rows for client B's SKUs, orders, batches and ledger events — proven by a database-level probe (in the shape of the existing `wms_rls_probe` tests), not only an API test. Tenant-level RLS does *not* provide client isolation; AD-3 scopes tenant + warehouse only.
- **D2C unchanged.** Every existing flow behaves identically after the client dimension lands, with no conditional client logic in the command layer.
- **Charges trace to the ledger.** Every billable event derives from movements already recorded — no new ledger event types, no parallel tally. Recomputing a period's charges must reproduce them exactly.
- **Storage bills duration**, not movement: whole days from a daily snapshot, in the way 3PL contracts are written.
- **An issued invoice is immutable.** Rate changes, corrections and late data produce a new document, never a mutation. Every invoice line traces to the ledger events that produced it — "defending the bill" is the requirement, and disputes are answered by expanding a line to its source events.
- **Cross-client operations stay possible.** A wave may span clients; isolation is about visibility and ownership, not partitioning the floor. This is most of a 3PL's efficiency.
- **Services GST, not goods GST.** Client billing uses SAC codes and services GST treatment — Epic 8's HSN/e-way path does not apply; shared machinery (basis-point rates, integer paise, invoice numbering), separate code path.
- **Non-goals:** tiered/volumetric pricing (flat rates only); payment collection, dunning, credit control; client-initiated order entry (portal is read-mostly plus ASN); per-client physical partitioning (commingled by default, dedicated storage is a bin attribute); EDI; multi-currency; splitting historical D2C data into multiple clients.

## Technical Decisions

- **AD-23 — client is a scoping dimension inside the tenant, defaulted and never nullable.** Exactly one system-owned `self` client per tenant (created with the tenant; precedent `bins.system_owned`). `client_id` is NOT NULL wherever it appears because a nullable scoping column turns every read into `OR client_id IS NULL` and the one that forgets is the leak.
- **AD-24 — isolation via a second RLS session variable `app.client_id`**, using the same fail-closed `NULLIF(current_setting(...), '')` idiom as AD-3. Operator sessions leave it unset and see the whole tenant; portal sessions set it, and the database — not the application — makes other clients' rows unreachable. Background jobs, projection rebuilds, export workers and reporting take explicit client context or deliberately none, mirroring AD-3's scoping.
- **AD-25 — billing is a projection over the ledger**, reusing AD-21's register-as-projection precedent. `storage_snapshots` is a rebuildable cache, not a book: replaying the ledger must reproduce it exactly, and a rebuild is the test. An invoice is a materialised snapshot recording its inputs.
- **`client_id` placement is selective.** Explicit NOT NULL columns only where queries filter/aggregate without joining through the SKU: `skus` (source of truth), `orders`, `purchase_orders`, `ledger_events` (billing aggregates over it constantly). Nullable by design: `bins.dedicated_client_id` (attribute, not scope) and `users.client_id` (null = 3PL staff, set = portal user). Tables that reference a SKU — stock, reservations, picks, order lines, GRN lines, putaway — inherit and get no column.
- **Rate cards** are versioned by effective date, never edited in place; `rate_card_id` is *recorded on the invoice* so a later re-render uses the card that actually applied. Four charge codes with closed `basis` vocabularies: `storage` (per unit per day), `inbound_handling` (per receipt line), `pick` (per pick), `outbound_handling` (per order) — each meters from an event the ledger already records (`storage_snapshots`, `grn.received`, `pick.picked`, `order.dispatched`). `charge_code`, `basis` and status sets use the repo's TS-tuple-plus-migration-CHECK pattern.
- **Invoice lifecycle:** `draft` (recomputable) → `issued` (frozen; no edit after `issued_at`) → `settled`/`disputed`/`void`; a correction is a new document. Money in integer paise; quantities in milli-units (AD-9 as amended).
- **ASN mirrors `purchase_orders`/`purchase_order_lines`** deliberately, so the GRN's reference document becomes "a PO or an ASN" — one receiving flow, same partial/blind/over-receipt handling.
- **Modules (AD-6):** new `clients` module (client entity, its users, portal scoping) and `billing` module (rate cards, metering, snapshots, invoices) — billing reads ledger events through the inventory facade and writes no stock; `inbound` gains the ASN document beside the PO. `architecture.spec.ts` gets the ownership block.
- **Two migrations, in order.** A (client dimension): create `clients`, insert one self client per tenant, add + backfill `client_id` on the four tables, set NOT NULL, add the nullable columns, extend every RLS policy with the client clause. B (billing/ASN/portal tables): purely additive. Guard both like 10.1's migration: fail-fast `RAISE`, pre-flight mapping check, post-migration assertion that every row carries a client.
- **Tests to pin:** migration A on the 10.1 harness against pre-client data; the DB-level client-isolation probe; a cross-client wave (isolation didn't cost efficiency); recompute equality of charges; rate-change immutability; snapshot rebuild reproduces billable units; TS vocabularies and DB CHECKs pinned together.
- **Repo conventions throughout:** UUIDv7 PKs, `tenant_id` on every table, no FK constraints (validated in the command transaction), RLS/CHECK only in migration SQL.

## UX & Interaction Patterns

- **Web only; mobile gains nothing new.** Floor work is deliberately client-agnostic and cross-client waves are untouched. Surfaces: client admin, rate cards, invoice review, ASN documents, per-client dashboards.
- **Portal is read-mostly plus ASN.** A client user completes a stock enquiry and an invoice review touching no operator-only surface and no other client's data.
- **Dispute flow:** an operator opens an invoice line — which names its charge code, basis, quantity and the rate card in force — and expands to the ledger events that produced the count, each with its actor, timestamp, order and SKU.
- The planning-era UX design docs predate this epic; no portal UX spec exists yet, so portal IA/interaction decisions are still open at spec time.

## Cross-Story Dependencies

- **Epic 21 depends on Epics 1 + 2** (tenancy, ledger). **Hard gate: 21-1 + 21-2 before 21-3…21-8** — the migration pair is Phase 0's slot; rate cards, metering, invoices, ASN, portal and reporting are additive in Phase 2 and follow demand.
- **21-1 lands after Epic 10's migration is merged and stable** — it is the programme's second one-shaped migration and reuses Epic 10's migration machinery, harness and review checklist. Story specs for 21-1 must carry the migration checklist and the AD-9-amendment precedent for one-shaped migrations.
- **Backend first:** additive backend changes (client dimension, billing endpoints, ASN) land before frontend surfaces that consume them; the meta repo's interface contracts update after each cross-repo change.
- **21-4/21-8 read the ledger** (and 21-4's snapshot rebuild depends on ledger replay); 21-7's portal is the consumer of AD-24 isolation, which 21-2 builds.
- **Storage billing basis:** per-pallet becomes the natural default once Epic 10-3's handling units land; the open default-basis question must be settled before 21-3/21-4 spec.
- **Deliberately not here:** subscription billing (the product billing the tenant) shares no tables or code with client billing and remains uncovered by any epic; client offboarding's ledger-history fate is an open question interacting with AD-16's retention architecture.