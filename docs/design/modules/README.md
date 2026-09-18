# Module designs

One document per module: what it owns, its public seam, its commands and their guards, its key algorithms, its invariants and the gotchas that have actually caused defects.

**Read the module doc before changing that module.** Read `../SYSTEM-DESIGN.md` first if you need the shape of the whole system, and `../IMPLEMENTATION-GUIDE.md` for the patterns every module shares.

Two cross-cutting references sit beside these: [`../API-SURFACE.md`](../API-SURFACE.md) — every route grouped by owning module, with its capability and error arms — and [`../PENDING.md`](../PENDING.md), everything known-but-not-done per module. **Check PENDING before speccing**: several entries are diagnosed defects whose fix is cheaper folded into related work than scheduled alone.

## Built

| Module | Doc | Owns |
|---|---|---|
| **inventory** | [`inventory.md`](inventory.md) | The append-only ledger, derived projections, reservations, ATP, reconciliation. **The core** — read this one first |
| **outbound** | [`outbound.md`](outbound.md) | Orders and the order state machine, waves, picklists, scan-verified picking, short-pick re-planning, pack, dispatch |
| **inbound** | [`inbound.md`](inbound.md) | Purchase orders, scan-based receiving, GRNs, over-receipt approval, QC hold and release |
| **putaway** | [`putaway.md`](putaway.md) | Directed putaway, bin administration (merge, retire) |
| **tenancy** | [`tenancy.md`](tenancy.md) | Tenants, auth, users, roles and capabilities, warehouses, zones, bins, device enrollment and badge-in |
| **catalog** | [`catalog.md`](catalog.md) | SKUs, CSV import, batches, serials, the UoM vocabulary |
| **carriers** | [`carriers.md`](carriers.md) | The carrier adapter registry and the tenant credential vault |

## Planned

| Module | Epic | Will own |
|---|---|---|
| `movements` | 5 | Transfer orders, stock adjustments with approval thresholds, cycle counts, variance review |
| `replenishment` | 6 | Reorder points, breach alerts, suggested POs, expiry and aging |
| `channels` | 7 | Channel connections, standing availability buffers, order ingestion, fulfilment writeback |
| `compliance` | 8 | GST invoicing, e-way bills, HSN summary — and later customs, excise and controlled-substance registers (epics 16–18) |
| `reporting` | 9 | Operational dashboard, notification panel, global audit trail, async export |
| `notifications` | 9 | The notification panel and mobile pushes |

Each is a spine placeholder today: a registered NestJS module with empty `providers` and `exports`, declaring the AD-6 boundary before anything implements it. `carriers` was one until story 4-6b, and the shape of that build is the model — the module already existed, so the story added providers rather than inventing a boundary.

## The rule that governs all of them

**A module owns its tables exclusively.** A sibling reaches it only through its facade or through an event — never by touching its tables, and never by importing past `*.facade`, `*.module` or `*.dto`.

`test/architecture.spec.ts` enforces this by scanning source for writes and past-the-facade imports, per module. When you add a module that owns tables, you add its block there too — and because the detector is only meaningful when something could violate it, the block includes hard-coded specifier strings that self-test the regex.

Where two modules genuinely need each other's reads, the join happens in the **api shell** (`src/api/`), not by one module importing the other. The device catalog snapshot is the worked example: it composes across `inbound` and `outbound` in the controller, because making `inbound` import `outbound` was tried, reverted, and is documented as having caused a cross-suite flake.
