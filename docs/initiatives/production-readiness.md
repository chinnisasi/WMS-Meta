# Production readiness — a multi-client 3PL, inbound to outbound to reports

> Status: **approved 2026-10-18** — every recommendation accepted (D1–D7), D3/D5/D8 answered by the owner. Source: four code audits (master data + inbound, inventory, outbound + returns, reports + billing + platform), with the load-bearing claims re-checked against the code. Every story below goes through the normal bmad-build loop (design → design review → code → code review), one at a time.

## Where we are

Strong today, no rework needed:
- The append-only, hash-chained stock ledger.
- Client isolation enforced by the database (RLS).
- Scan-verified receive → putaway → pick → pack → dispatch on an offline-first handheld.
- FEFO picking.
- Over-receipt approval.
- Directed putaway with capacity, storage-class and hazard gates.
- Cycle-count variance approval.
- Rate cards, metering and monthly GST services invoices per client.
- The client portal (read, plus ASN).
- The audit trail.

What blocks running real clients is mostly around that core:
- master data that is per company instead of per client;
- what the dock records;
- floor tools for moving and correcting stock;
- real couriers;
- client paperwork, exports and notifications;
- everything needed to deploy and operate it.

## Decisions needed before Phase 1 (the owner's)

| # | Decision | Recommendation |
|---|---|---|
| D1 | SKU code and barcode unique **per client** instead of per company. Today two brands cannot both have `TSHIRT-M` or share a GTIN. | **Agreed 2026-10-18:** Yes. A scan resolves by client: through the document being received or picked, or a client prompt on a blind receipt. |
| D2 | Who places POs: 3PL staff for a client, the client in the portal, or only the 3PL for its own goods. | **Agreed 2026-10-18:** Staff for a client first; portal later. |
| D3 | ~~Vendors belong to one client, or are shared~~ | **Answered 2026-10-18: a vendor can serve several clients.** Design (recommended): a tenant-wide **business partner** (one per real company — GSTIN unique in the tenant, legal/trade name, PAN, registered and dispatch addresses, contacts, active/blocked) plus a **client link** (many-to-many: the client's own vendor code, active per client, lead time). A PO names its client and its vendor must be linked and active for it. The portal sees only its own links. Documents freeze the partner's name, GSTIN and address at creation. The same model carries **consignees** (B2B ship-to) and **transporters** (shared, no client link). |
| D4 | Client B2B shipments: who issues the tax invoice or delivery challan and the e-way bill — the brand (the 3PL records its numbers) or the 3PL on the brand's GSTIN. | **Agreed 2026-10-18:** The brand issues; the 3PL records the invoice/challan number and generates or records the e-way bill. |
| D5 | ~~First couriers~~ | **Answered 2026-10-18: parked.** Clients arrange their own couriers; the warehouse captures the shipment data (courier, AWB/LR, handover) and sends the client a scanned copy of the signed outbound documents. A courier aggregator or direct integration is a later, optional story |
| D6 | Hosting. | **Agreed 2026-10-18:** AWS Mumbai (ap-south-1): managed Postgres, Valkey, S3. |
| D7 | Labels: thermal (Zebra ZPL) or A4/PDF. | **Agreed 2026-10-18:** Both, ZPL first for the dock and pack stations. |
| D8 | ~~The first go-live client's profile~~ | **Answered 2026-10-18: the warehouse holds every kind of goods.** That covers FMCG, food, pharma, cold chain, electronics, apparel, hazardous, high-value and bulky. The goods-type stories (serials, expiry, recall, DG, freight, value-added work) are therefore go-live. |

## Cross-cutting design rules (apply to every story)

- **Documents freeze what they print.** A PO, GRN, invoice, challan or return-to-vendor stores the party's name, GSTIN and address at creation; a later master edit never rewrites it.
- **Master records deactivate, never delete.** A client, partner, SKU, bin or user with history is set inactive; inactive records cannot be picked on new documents.

## Roadmap

★ = go-live blocker for the first real client. Phases are ordered by dependency. Phase 6 (platform) can run in parallel from the start. **Totals: 44 stories, 38 ★ go-live.**

### Phase 1 — Multi-client foundations (data model first, because later work builds on its keys)
| # | Story | What it adds |
|---|---|---|
| 1.1 ★ | Per-client SKU identity | Code and barcode unique per (client); scan resolution by document client; migration + device catalog change (D1) |
| 1.2 ★ | Client master completion | Contacts (name, email, phone), registered and return addresses, offboarding (`departed`) — **1-2a**; and a **per-client receiving policy**: receiving tolerance, QC on receipt, expiry required + minimum remaining shelf life — **1-2b** (allocation FEFO/FIFO moved to 4.3) |
| 1.3 ★ | Business partner master | One record per real company with roles vendor / consignee / transporter; GSTIN-deduplicated; client links (many-to-many) for vendors and consignees; documents snapshot the party; Settings → Partners (list, add, edit, link to clients, deactivate) (D3) |
| 1.4 ★ | SKU master on the web | Single SKU create and full edit (dimensions, storage class, hazard), shelf life, multiple barcodes, case/pallet pack levels with their own barcodes |
| 1.5 ★ | Client segregation | A client filter on every list and the stock/ledger reads; dedicated client bins enforced in putaway, moves and merge |
| 1.6 ★ | Goods-type attributes and licences | Per SKU: drug schedule, food/allergen category, DG UN number + class + packing group, SDS document, high-value, fragile, max stack height. Drug and FSSAI licences on the client and warehouse, with expiry warnings. The segregation matrix extended to food, allergens and chemicals |

### Phase 2 — Inbound: the production dock
| # | Story | What it adds |
|---|---|---|
| 2.1 ★ | PO create form | Client → that client's vendors and SKUs; kit guard (spec draft `spec-po-create-form.md`, to be rewritten on 1.3) |
| 2.2 | PO import | CSV/Excel, reusing the ASN import |
| 2.3 ★ | Gate-in and receipt header | Vehicle number, transporter, LR/AWB, driver, supplier invoice/challan number + date, inward e-way bill, seal number + intact, packages declared vs counted, gate-in / unload start-end, dock door; optional appointment |
| 2.4 ★ | Receipt line capture | Expiry derived from SKU shelf life (after 1.4), good / damaged / short quantities with reason codes (damaged → a damaged location, not sellable), temperature on arrival for cold-chain SKUs. *(Expiry capture and the minimum-remaining-life check per client policy shipped in 1-2b.)* |
| 2.5 ★ | Damage photos | Photo attachments on a receipt (needs file storage — S3) |
| 2.6 ★ | Serial/IMEI capture at receipt | Scan serials or IMEIs on the handheld at receiving |
| 2.7 | Desk receiving on the web | Receive against a PO/ASN at a desk (small sites, scanner down) |
| 2.8 ★ | QC inspection outcome | Inspection pass/fail on a receipt QC hold, including the **"QC fail" disposition** deferred by 1-2b (decision 7); partial reject → return to vendor. *(Per-client auto-holds on receipt, release and release-per-receipt shipped in 1-2b.)* |
| 2.9 ★ | GRN document + client confirmation | Printable/exportable GRN with the header and damage details; GRNs in the portal; email/webhook on receipt (needs 5.1) |
| 2.10 ★ | Labels | Bin labels; pallet/carton (LPN) labels at receiving; ZPL + PDF (D7) |

### Phase 3 — Inventory control on the floor
| # | Story | What it adds |
|---|---|---|
| 3.1 ★ | Bin-to-bin moves | Handheld + web (the Moves page is a placeholder today) |
| 3.2 ★ | Stock adjustment screen | Web + handheld, on the existing reason codes and approval thresholds |
| 3.3 ★ | Stock statuses | Damaged / blocked locations, a batch block verb, ATP excludes expired and blocked batches |
| 3.4 | Pick-face replenishment | Min/max per pick face → move tasks |
| 3.5 ★ | Counts | Blind counts on the handheld, count scheduling on the web, full stock take with freeze |
| 3.6 | LPN / pallet tracking | License-plate identity for pallets and cartons through putaway, moves and picking (pairs with 2.10) |
| 3.7 ★ | Batch recall | Block a batch in every warehouse at once, list where it sits, trace every shipment that carried it; a client recall report |
| 3.8 ★ | Value-added work orders | Kitting/assembly into real stock, relabelling, bundling, gift wrap — each billed to the client (pairs with 5.5) |

### Phase 4 — Outbound and returns
| # | Story | What it adds |
|---|---|---|
| 4.1 ★ | Order intake for clients | CSV/Excel order import; portal order entry; client order number |
| 4.2 ★ | Order fields and lifecycle | B2B/B2C, COD, priority and ship-by date; cancel/unpack a packed order; backorder follow-on |
| 4.3 ★ | Per-client allocation rules | FEFO for perishables and pharma, FIFO otherwise, and minimum remaining shelf life to the customer — its own fields on the client policy row 1-2b added (1-2b decision 1) |
| 4.4 ★ | Client-arranged shipping capture | The client sends its own courier or transporter. **Labels, both ways:** (a) the client uploads ready-made label PDFs per order (portal, API or ops upload), which print at the pack station and are scan-verified onto the parcel; (b) the courier brings labels at pickup, and the AWB is captured by scanning at handover. Per shipment: courier, AWB/LR, cartons and weight, the pickup person and vehicle, handover time. **Documents, both:** a courier-signed handover manifest per pickup, and every outbound document per shipment (invoice/challan, e-way bill, POD) scanned or photographed, attached and shared with the client (portal + email). Courier API integration stays an **optional** later story (D5) |
| 4.5 ★ | Packing documents | Multi-carton shipments, packing slip, carton labels |
| 4.6 ★ | Client consignment compliance | Brand invoice/challan recorded, e-way bill for client goods (D4) |
| 4.7 ★ | Returns disposition | Restock / quarantine / scrap / return to client or vendor; blind returns without an RMA |
| 4.8 | Marketplaces | Amazon.in, Flipkart; the Shopify variant-lookup fix |
| 4.9 ★ | B2B freight dispatch | Truck / LTL / FTL for bulky and pallet goods: vehicle, transporter, LR, loading sheet, proof of delivery |
| 4.10 ★ | Dangerous-goods shipping documents | The DG declaration and hazard labels on a DG shipment, and a warning when it is handed to a courier the client has not marked DG-capable |

### Phase 5 — Visibility, notifications, billing
| # | Story | What it adds |
|---|---|---|
| 5.1 ★ | Email service | Invites, password reset, invoice delivery, alerts (no mailer exists today) |
| 5.2 ★ | Client notifications | Outbound webhooks + email on receipt and dispatch; tracking in the portal |
| 5.3 ★ | Operational reports | Client filter + CSV/Excel export on: stock on hand, inbound register, outbound register, ledger, ageing / near-expiry; then space utilisation, operator productivity, count accuracy |
| 5.4 ★ | Portal self-service | Downloads of those reports and the GRN/dispatch documents; the client manages its own portal users |
| 5.5 ★ | Billing for real contracts | Value-added and ad-hoc charges, minimum monthly charge, tiers |
| 5.6 ★ | GST correctness | Credit/debit notes; e-invoice IRN for e-invoicing GSTINs |

### Phase 6 — Platform and security (parallel from day one)
| # | Story | What it adds |
|---|---|---|
| 6.1 ★ | Auth hardening | Fix the handheld-token-on-web defect (PENDING finding #1, verified); refresh tokens and sign-out; password reset; login rate limit and lockout; 2FA for owners |
| 6.2 ★ | Deployability | Dockerfiles, staging + production environments, a deploy pipeline, a secrets manager, safe migrations (concurrent index builds) (D6) |
| 6.3 ★ | Operate it | Backups with a tested restore, logs / metrics / alerts, a readiness check, the storage-snapshot job alerting |
| 6.4 | Compliance | India data residency, audit of sign-ins and downloads |

## Suggested order

1. **6.1:** the security defect, first.
2. **D1–D8:** settle the decisions.
3. **Phase 1:** 1.1 → 1.2 → 1.3 → 1.4 → 1.5.
4. **Phase 2 ★** stories.
5. **3.1–3.3.**
6. **Phase 4 ★** stories.
7. **Phase 5 ★** stories.

Phase 6.2–6.3 runs alongside, so staging exists before Phase 2 ends. The non-★ stories (2.2, 2.7, 3.4, 3.6, 4.8, 6.4) follow. **Parked:** courier API integration (aggregator or direct).
