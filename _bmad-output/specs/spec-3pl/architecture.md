# Architecture — the client dimension

Companion to `SPEC.md`. Two proposed spine decisions, the isolation model, and what they do to the existing AD-1…AD-22 set.

## The correction this rests on

`ARCHITECTURE-SPINE.md` says, under *Deferred*:

> 3PL multi-client billing (v2) stays reachable through AD-3 tenancy — no single-client assumptions anywhere.

**That reassurance is weaker than it reads.** AD-3's rule is `tenant_id` + `warehouse_id` on every row, with Postgres RLS behind the app layer. For a 3PL, clients are **not** tenants — they share one warehouse, one bin grid, one operator workforce, one badge-in, and cross-client waves are most of what makes the operation efficient. Making each client a tenant would forfeit all of that.

So client is a **third scoping dimension that does not exist today**, and RLS as currently written cannot enforce it, because every policy keys on `app.tenant_id` alone. "Reachable" is true only in the sense that nothing blocks adding a dimension. It does not mean the dimension is there.

## AD-23 — Client is a scoping dimension inside the tenant, defaulted and never nullable `[PROPOSED]`

- **Binds:** all repos; CAP-1, CAP-2, CAP-3
- **Prevents:** cross-client leakage; a per-tenant "3PL mode" branch through every command
- **Rule:** every tenant has exactly one **system-owned `self` client**, created with the tenant. `client_id` is `NOT NULL` wherever it appears. **D2C is the one-client case of the 3PL model, not a separate mode** — no command, query or surface branches on whether the tenant is a 3PL.
- **Why not nullable:** a nullable scoping column makes every read carry `OR client_id IS NULL`, and isolation fails at the one query that forgets. A defaulted non-null column has one code path.
- **Where it lives:** the SKU is the source of truth; most tables inherit the client by reference. Explicit columns exist only where a query filters or aggregates *without* joining through the SKU — see `schema.md`.

## AD-24 — Client isolation is enforced by a second RLS session variable `[PROPOSED]`

- **Binds:** wms-be; CAP-2, CAP-8
- **Prevents:** a portal query, report, export or background job returning another client's rows
- **Rule:** RLS policies gain a client clause keyed on `app.client_id`:

  ```sql
  USING (
    tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid
    AND (
      NULLIF(current_setting('app.client_id', true), '') IS NULL
      OR client_id = NULLIF(current_setting('app.client_id', true), '')::uuid
    )
  )
  ```

  An **operator session** leaves `app.client_id` unset and sees the whole tenant, so cross-client waves and floor work are untouched. A **client-portal session** sets it, and the database — not the application — is what makes another client's rows unreachable.
- **Why this shape:** the leak risk is concentrated in one place (the portal, where an untrusted party holds a session), and this puts enforcement below every surface, query, report and export at once. It is the same fail-closed `NULLIF(current_setting(...), '')` idiom AD-3 already relies on.
- **Scoping extends where AD-3's does:** background jobs, projection rebuilds, export workers and reporting all take explicit client context or deliberately none.

## AD-25 — Billing is a projection over the ledger `[PROPOSED]`

- **Binds:** wms-be; CAP-5, CAP-6, CAP-7
- **Prevents:** a billing book that drifts from the movements it bills for
- **Rule:** charges derive from ledger events plus the rate card in force. **Handling charges are already ledger events** — `grn.received`, `pick.picked`, `order.dispatched` — so metering is aggregation, not new instrumentation. **Storage needs duration**, which the ledger does not hold directly, so a daily snapshot job records billable units per client per day; that snapshot is a **rebuildable projection, a cache and not a book**, and replaying the ledger must reproduce it. An **invoice is a materialised snapshot** recording its inputs, immutable once issued, so it can be recomputed, explained and disputed.
- **Precedent:** the same rule AD-21 gives customs, excise and controlled-substance registers — *registers are projections over ledger events, never a separately maintained book*. Reusing it means one mechanism, not two.

## Effect on the existing decisions

| AD | Effect |
|---|---|
| **AD-1** ledger is the only stock truth | **Strengthened.** Ownership becomes answerable from the ledger, and billing derives from it |
| **AD-3** tenant + warehouse scope | **Extended, and its 3PL note corrected.** Client is a third dimension AD-3 does not provide |
| **AD-5** idempotency | Unchanged — keys stay tenant-scoped; client is carried in the payload, not the key |
| **AD-6** module boundaries | A new `clients` module owns the client entity; a new `billing` module owns rate cards, metering and invoices, and reads the ledger through the inventory facade |
| **AD-9** integer primitives | Unchanged — money stays integer paise, and rates are paise too |
| **AD-11** registered ledger grammar | Unchanged. Billing adds **no** event types; it reads the ones that exist |
| **AD-12** reservations | **Client-scoped by inheritance.** A reservation references a SKU, and the SKU carries the client, so client A's order can never draw client B's units |
| **AD-16** tamper-evident audit | **Interacts with client offboarding** — see the open question in `SPEC.md` about departed clients' history |
| **AD-21** fiscal/legal state | **Precedent reused** by AD-25 rather than duplicated |
| **AD-22** handling units | Unchanged, and useful: storage billed per pallet wants the handling unit Epic 10-3 introduces |

## Module boundaries (AD-6)

```
clients   — the client entity, its users, its portal scoping. Owns `clients`.
billing   — rate cards, metering, storage snapshots, invoices. Owns its own tables.
            Reads ledger events through the inventory facade; writes no stock.
inbound   — gains the ASN document beside the PO (same module, same GRN flow).
```

`billing` must not write inventory tables, and `architecture.spec.ts` gets the same ownership block every other module has.

## Sequencing

The client dimension is **migration-shaped**, like AD-9's quantity change: it touches tables that later epics will add more of, and every epic built without it is one to revisit. It belongs in **Phase 0**, beside epics 10 and 11 — not after epic 20.

Billing, the portal, ASN and per-client reporting are all **additive** on top of it and can follow demand, in the same way the multi-domain tiers are additive on top of the quantity model.
