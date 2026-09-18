# Diagrams

Companion to `SPEC.md`. Per the spec convention, all diagrams live here rather than in the kernel.

## The client dimension: where it sits

```mermaid
graph TD
  T[tenant — the 3PL operator] --> C1[client: Acme Foods]
  T --> C2[client: Bright Apparel]
  T --> CS["client: self (system_owned)"]

  C1 --> S1[skus]
  C2 --> S2[skus]
  CS --> S3["skus — the D2C case"]

  S1 --> ST[stock_on_hand · batch_on_hand · reservations]
  S2 --> ST
  S3 --> ST

  T --> W[warehouse — ONE building]
  W --> B[bins — commingled by default]
  ST --> B

  classDef sys fill:#1E4E8C,color:#fff
  class CS sys
```

**What the picture is saying:** clients sit *inside* one tenant and share the warehouse and the bins. That sharing is the point — a 3PL's efficiency comes from one operator walking one route for two clients. D2C is the same shape with a single system-owned client, which is why no code branches on "3PL mode" (AD-23).

## Isolation: one policy, two session shapes

```mermaid
graph LR
  OP[operator session<br/>app.tenant_id set<br/>app.client_id UNSET] --> RLS{RLS policy}
  CL[client portal session<br/>app.tenant_id set<br/>app.client_id SET] --> RLS

  RLS -->|client clause is null-tolerant| ALL[every client's rows<br/>cross-client waves work]
  RLS -->|client clause binds| OWN[only that client's rows]
```

The same policy serves both. An operator leaves `app.client_id` unset and the clause is satisfied trivially; a portal session sets it and the database makes other clients unreachable — below every surface, query, report and export at once (AD-24).

## Billing: aggregation, never a second book

```mermaid
graph LR
  LE[(ledger_events)] -->|grn.received| IH[inbound_handling]
  LE -->|pick.picked| PK[pick]
  LE -->|order.dispatched| OH[outbound_handling]
  LE -->|daily job| SS[(storage_snapshots)]
  SS --> STG[storage]

  IH --> CALC{meter × rate card}
  PK --> CALC
  OH --> CALC
  STG --> CALC

  RC[(rate_cards<br/>versioned by effective date)] --> CALC
  CALC --> INV[(client_invoices<br/>immutable once issued)]
  INV -.->|every line traces back| LE

  classDef proj stroke-dasharray: 5 5
  class SS proj
```

Three of the four charges are aggregations over events that already exist. **Storage is the exception** — it needs duration, so a daily snapshot stands in, drawn dashed because it is a rebuildable projection and not a source of truth (AD-25).

The dotted return arrow is the requirement the whole design serves: **every invoice line traces back to the events that produced it.** Billing a client is easy; defending the bill is the hard part.

## Inbound: the ASN sits beside the PO

```mermaid
graph TD
  PO[purchase_order<br/>authored by the BUYER] --> GRN[goods receipt]
  ASN[advance_shipment_notice<br/>announced by the CLIENT] --> GRN
  GRN --> LED[(ledger_events)]
  LED --> STOCK[stock_on_hand]
```

An ASN is a second *reference document* for the same receiving flow, not a second flow. Partial, blind and over-receipt handling are unchanged (CAP-9) — the only difference is who authored the expectation.
