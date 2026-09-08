# Security & Compliance Review — Architecture Spine (WMS v1 Platform)

- **Reviewer:** Security & compliance review (India-first multi-tenant warehouse SaaS)
- **Date:** 2026-09-08
- **Inputs reviewed:**
  - `_bmad-output/planning-artifacts/architecture/architecture-WMS-Meta-2026-09-08/ARCHITECTURE-SPINE.md` (AD-1…AD-10, conventions, stack, structural seed, capability map, deferred)
  - `_bmad-output/planning-artifacts/prds/prd-WMS-Meta-2026-09-07/prd.md` (§ Cross-Cutting NFRs, § Constraints and Guardrails, FR-3, FR-26, FR-28)
- **Verdict:** **Conditionally adoptable — gaps are architectural, not cosmetic.** The spine is strong on inventory correctness and module discipline (AD-1, AD-2, AD-5, AD-6 are genuinely security-relevant) but is **silent or thin on six of the eight axes audited**: third-party credential handling, audit tamper-evidence/retention mechanics, mobile device trust, session/role-revocation semantics, non-API tenant-scoping paths, and the cost-guardrail circuit breaker. Every gap below has a proposed tightened rule; none requires re-architecting, but all should be adopted before FR-24/FR-26/FR-28/wms-mobile builds begin.

**Severity scale:** Critical = exploitable or compliance-fatal if built as specified; High = likely incident/compliance finding; Medium = real risk, manageable if caught at build time; Low = hygiene.

---

## 1. Tenant isolation (AD-3) — scoping is specified, but only on the API hot path

**AD-3 is a good invariant**: `tenant_id` everywhere, warehouse as first-class partition key, base-layer scope injection, RLS as defense-in-depth. It fails to hold, however, on every path that is *not* a user-initiated API call — and the spine names several such paths without binding them to AD-3.

### S-1. Background jobs, projection rebuilds, and reporting projections are outside AD-3 — HIGH

- The spine's own components create unscoped paths: `jobs/` (scheduler: reconciliation, availability sync, nightly slotting, alerts), the reporting module (dashboard projections over ledger events, FR-27), replay-reconciliation (AD-1/NFR-1), and the outbox relay (AD-7).
- Projection rebuilds and reconciliation *must* read across tenants by design (that's what a global replay does). Nothing in the spine says these jobs (a) re-derive `tenant_id` from the events they consume rather than trusting job context, and (b) write projections under a job-context `tenant_id` that RLS also honors. If the rebuild job runs as a superuser or table owner, **RLS is bypassed silently** (Postgres RLS does not apply to table owners or `BYPRLS` roles by default) — so a bug in the rebuild writes tenant A's rows into tenant B's projection with no last line of defense.
- **Tightened AD-3 rule (add):** *"Every execution context — API request, background job, webhook consumer, outbox relay, projection rebuilder, export worker — establishes a tenant/warehouse context before its first query; context is propagated in the command service entry point (AD-10), not inferred from arguments. Cross-tenant maintenance jobs (ledger replay, global reconciliation) run under a dedicated `MAINTENANCE` role that is explicitly RLS-exempt, writes no tenant-scoped rows outside the ledger, and emits a per-tenant audit record for any cross-tenant read it performs. The RLS-exempt role list is a reviewed, testable constant. RLS policies are verified by a CI test that connects as the application role with no tenant context and asserts every table denies reads."*

### S-2. Connection pooling can leak tenant context across queries — MEDIUM

- RLS-as-defense-in-depth only works if `tenant_id` is set **per transaction** (`SET LOCAL app.tenant_id`) and the pool (RDS Proxy / driver pool) resets it. With transaction-level pooling, one missed reset gives tenant B tenant A's session variables. The spine's stack table lists RDS Postgres but says nothing about pooling discipline.
- **Add to AD-3:** *"Tenant context is set with `SET LOCAL` inside each transaction; no session-level GUCs; poolers are transaction-pooling and the application asserts context is set before every query in the base repository layer (fail closed, not default-open)."*

### S-3. Audit/reporting **exports** (FR-28) are a tenant-isolation edge — HIGH

- FR-28 is an Owner-facing export of 100k+ events, produced asynchronously. The export job is a background writer (S-1 applies) *and* produces a durable artifact (presumably S3, per the stack) delivered via URL. Three holes: (a) the export writer must carry the requesting Owner's tenant scope end-to-end — the export request record itself must be tenant-scoped so a job can never be re-pointed at another tenant; (b) delivery artifacts are long-lived files sitting in a shared bucket — bucket must be partitioned per tenant with a deny-by-default policy, artifacts encrypted, presigned URLs short-TTL, and every artifact accession logged as an audit event; (c) nothing bounds export size/eligibility by role — FR-28 gives Owners export, but the spine should forbid export payloads from bypassing AD-10 (export content is generated through the same scoped query layer, never a raw SQL dump).
- **Add (new rule, see AD-14 proposal in §4):** *"Exports are request-scoped: an export job's tenant scope is pinned at request time, immutable during execution, and its output is written to a per-tenant prefix with SSE-KMS, a short-TTL presigned download, single-download logging, and automatic deletion after N days. Export content is produced only through the module's scoped read interfaces (AD-6/AD-10); ad-hoc SQL dumps are prohibited."*

### S-4. Mobile offline cache on a lost/stolen device — HIGH

- AD-4 gives each device a **SQLite WAL cache of tenant data** (tasks, bins, SKUs, batch/serial, stock levels for its picklists) plus an outbox. The spine says nothing about what happens when the device is lost — which in a warehouse with shared/commodity handsets is a *when*, not an *if*. The cached data is enough to map a competitor's warehouse (bins, SKUs, quantities) and the outbox can potentially be replayed.
- There is also no device identity concept anywhere in the spine: FR-29 "badge-in" is a scan gesture, not a device trust model. Nothing binds a session to a device, nothing revokes it, nothing wipes it.
- **Tightened AD-4 rule (add):** *"The offline store is encrypted at rest (SQLCipher/OS keystore-backed key), keyed to the logged-in operator session. Device enrollment is explicit: a device is registered to a tenant (and optionally a warehouse) and issued a device credential; sessions are revocable server-side. On revocation or 30 days without check-in the device is refused at next sync and its queued outbox is discarded (never replayed from a revoked device). A remote-wipe signal (clear offline store on next contact) is supported for lost devices; maximum offline cache scope is limited to assigned/active tasks plus the bin/SKU catalog needed to serve them — never whole-warehouse stock projections."*
- Related consequence: **an offline device whose operator was deactivated must not keep scanning into a queue that will later be honored.** See S-8.

### S-5. Valkey reservation keys are not stated to be tenant/warehouse-namespaced — MEDIUM

- AD-2 puts ATP state in Valkey keys with no stated key scheme. A shared hot-state tier is the classic place a multi-tenant bug becomes a cross-tenant oversell or availability leak. Low probability, severity-1 blast radius (NFR-4).
- **Add to AD-2:** *"Reservation keys are namespaced `t:{tenant_id}:w:{warehouse_id}:sku:{sku}`; the Lua script validates the key's tenant/warehouse prefix against the caller's context and refuses otherwise."* Cheap, closes a class of bug that would otherwise be found in production.

---

## 2. Third-party integration secrets — no invariant exists at all — CRITICAL

This is the largest single gap. The spine wires up Shopify/Amazon/Flipkart adapters (channels module), carrier adapters (Delhivery/Blue Dart/Ecom/Shiprocket), and a GST/e-way gateway (portal API or GSP intermediary, PRD OQ3) — every one of which requires **per-tenant long-lived credentials**: Shopify OAuth access/refresh tokens, Amazon SP-API LWA refresh tokens, Flipkart app tokens, carrier API keys/account PINs, GSP client credentials or GST portal credentials. AD-7 governs *delivery* of integration events; nothing governs the *credentials* that make those calls.

Absent from the spine entirely: storage, encryption, rotation, blast-radius containment, audit of use, and offboarding.

- **Storage:** no rule that per-tenant integration secrets are encrypted at rest with a tenant-scoped key (envelope encryption, KMS key per tenant or per-tenant data key), never in env vars, never in a plaintext column, never logged (the structured-log convention `tenant_id/warehouse_id/request_id` has no companion rule about secrets redaction).
- **Rotation:** Shopify/Amazon refresh tokens expire and are rotated by the platforms themselves; the spine needs a rotation-ready secret store with versioned secrets and zero-downtime rotation, plus an alert on an expiring-soon token (a dead channel token is also an *availability* problem — sync silently stops, buffers go stale, oversell risk).
- **Offboarding/deprovision:** no rule that disconnecting a channel (or offboarding a tenant) destroys the stored credential. Multi-tenant SaaS data-deletion obligations (PRD "tenant data isolated and exportable") implicitly include credentials.
- **GSP/GST credentials** are the most sensitive: a GSP intermediary credential effectively grants filing-adjacent capability on the tenant's GSTIN. Same treatment, plus: credentials must never be exposed to the frontend, and GST-adjacent data residency (see §6, S-14).
- **Proposed new invariant AD-11 — Third-party credentials are tenant-scoped, encrypted, rotatable, and auditable `[NEW — ADOPT before FR-24/FR-17/FR-26 builds]`:**
  - *Binds:* channels, carriers, compliance, notifications modules; shared config.
  - *Rule:* every third-party credential lives in the secrets store (KMS envelope-encrypted per tenant, versioned), referenced by id from channel/carrier config — never inline. Secret material is readable only by the owning module's adapter process, never serialized into logs, error envelopes (RFC 9457 bodies), exports (FR-28), or audit trails. Platform-initiated rotation (OAuth refresh) and manual rotation are both supported with versioned zero-downtime swap; expiry is monitored with alerts ahead of deadline. Disconnecting a channel/tenant deletes its secrets and records the deletion in the audit trail. Every use of an integration credential is attributable in logs to `tenant_id` + integration + purpose.

---

## 3. Authn/authz — one line of conventions; the FR-3 consequence is unmodeled — HIGH

The spine's entire authentication story is: *"auth = short-lived JWT + refresh, roles Owner/Ops Manager/Operator/Accountant per FR-3."* That is a naming, not a model. Consequences:

### S-6. FR-3's "role changes take effect on the user's next action, not next login" contradicts an unqualified JWT design — HIGH

- "Short-lived JWT" with embedded roles means a demoted operator keeps their old role until token expiry; a promoted one is gated until expiry. FR-3's testable consequence demands *next-action* effect. Two coherent resolutions, and the spine must pick one:
  1. **Role epoch/claim version:** tenancy module keeps a per-user `role_epoch`; every mutation command (AD-10) re-reads the epoch server-side and re-evaluates permissions from the DB (JWT carries identity, not authorization). This is the correct choice for a system where AD-10 already funnels every mutation through command services — authorization belongs at that choke point, refreshed per action, not cached in the token.
  2. Push-based token invalidation (revocation list in Valkey keyed by `jti`/user). Weaker: fails offline (mobile must keep working offline), so option 1 is the fit.
- **Tightened rule (add to conventions + AD-10):** *"Access tokens authenticate identity only; authorization is re-evaluated at each command-service entry against the current role record (per FR-3 'next action' semantics), with a per-user role epoch cached for read-path performance. Token lifetime ≤ 15 min. Revoking a user or role denies the next API action and the next offline sync — never only at next login. All role/permission changes are audit-logged (FR-3) and include the actor making the change."*

### S-7. Refresh/session model, device sessions, and operator lifecycle are unspecified — HIGH

- No refresh-token rotation/reuse-detection, no concurrent-session policy, no session revocation on user deactivation (critical in a warehouse: a deactivated operator's badge shouldn't work an hour later), no device-bound sessions for mobile (S-4), and no stated MFA position for the Owner role — the role that can export the entire audit trail (FR-28) and approve stock adjustments (FR-19). For an India-first B2B SaaS, Owner-role MFA should at minimum be a declared decision, not silence.
- **Add:** *"Refresh tokens rotate on use with reuse detection (reuse ⇒ revoke the family); sessions are revocable server-side and bound to device for mobile (AD-4). Deactivating a user immediately denies API access and device sync. MFA is required for the Owner role `[decision to ratify; recommended: yes for v1]`. Web and mobile session policies are stated per client type."*

### S-8. Offline authorization gap: revoked/deactivated device queues operations that get honored later — HIGH

- AD-4 replays the outbox "in task order with client-generated ULID keys," and AD-10 says command services enforce gates — good — but the spine never states that **each replayed item is re-authorized at replay time against the then-current session/role/device state**, and that replay from a revoked session/device is rejected wholesale (with operator-visible queue state, per AD-4's "queue state shown as queue depth"). Otherwise a demoted or ex-operator's queued over-receipt or adjustment applies because the *scan* happened while authorized.
- **Add to AD-4/AD-10:** *"The outbox carries the session/device identity per item; the command layer re-validates actor status, device enrollment, and task assignment at replay time. Items failing re-validation are quarantined to human review (same escalation path as conflicts), not silently dropped or applied."*

---

## 4. Audit retention (NFR-5: ≥ 7 years) — stated as a number, with no architecture behind it — CRITICAL

FR-4 makes the **ledger** immutable and AD-1 makes it the truth; FR-28 puts an audit trail + export in the reporting module. But the audit requirement in NFR-5 is broader than the ledger ("every state change attributable to actor, time, and reference") and the spine is silent on four things that determine whether the 7-year claim survives contact with reality:

### S-9. No tamper-evidence, and "immutable" is only as strong as the DB credentials — HIGH

- The ledger is append-only at the application layer. A compromised host, a support tool, or a buggy migration can UPDATE/DELETE ledger rows; nothing detects it beyond replay-reconciliation, which checks *derived state against the ledger* — if the ledger itself is edited, replay reconciles fine against the edited history. That is the exact blind spot.
- **Proposed new invariant AD-12 — Audit and ledger events are tamper-evident and retained 7 years `[NEW — ADOPT before FR-28 build]`:**
  - *Rule:* the audit trail (FR-28) and the ledger (FR-4) are append-only with application-denied UPDATE/DELETE (RBAC-locked, RLS-denied), plus a **periodic hash chain** (each day's event digest links to the previous) anchored outside the database (e.g., digest object written to S3 Object Lock / WORM in compliance mode). Any gap or mismatch in the chain is a severity-1 alert (same channel as NFR-1 divergence). Retention ≥ 7 years with a documented storage lifecycle (Postgres → S3 Glacier-class archive past N months) and a verified restore path — a 7-year retention that cannot be *retrieved* at year 6 fails the NFR.
  - *Export tamper-evidence:* every FR-28 export is itself a durable artifact with a computed digest recorded in the audit trail (what was exported, by whom, when, digest of the file), so the export can later be shown to match what the system held. Exports are generated through scoped read interfaces (S-3) and cannot be re-run against a different tenant (S-1).

### S-10. PII inside a 7-year audit trail — MEDIUM

- The audit trail attributes every action to an actor for 7 years. Actor records will contain names, phone numbers (invite flows), device ids. Retaining personal data 7 years "because GST" is only defensible for records that are genuinely book-keeping records; user account data and contact details are not. There is no data-minimization rule and no position on India's DPDP Act 2023 (consent notice, data-principal erasure requests, breach notification to the Board) — for a product whose stated compliance posture is "India-first," that is a named gap, even if full DPDP program design is out of spine scope.
- **Add:** *"Audit events carry actor identity by user id + role at time of action; contact-level PII lives in the tenancy module and is minimized/pseudonymized in audit payloads. Tenant data deletion (offboarding) honors NFR-5 for financial/compliance records while purging non-record PII; a DPDP data-subject request path (export + erasure) is an explicit v1 non-goal or a planned fast-follow — decide, don't stay silent."*

---

## 5. PII / data governance (PRD: "isolated and exportable; no cross-tenant analytics") — MEDIUM

The PRD's privacy constraint is a promise; the spine never operationalizes it.

- **Exportability:** FR-28 exports the *audit trail*, not the tenant's data. "Tenant data is isolated and exportable" needs a whole-tenant export story (catalog, ledger, documents, audit) — at minimum a stated v1 position (even if it is "offboarding dump, async, per request").
- **No cross-tenant analytics:** nothing forbids cross-tenant queries, shared benchmark dashboards, or ML training on tenant data. The reporting module reads ledger events and is the natural place this leaks. **Add to AD-3:** *"No code path may aggregate across tenants; reporting is tenant-scoped by construction. Any future aggregated/benchmark feature requires explicit aggregation + consent per PRD and is a new invariant, not a query."*
- **Marketplace API terms:** the PRD constraint (respect Amazon/Flipkart/Shopify retention & sync terms) maps to data minimization in the channels module — order payloads stored beyond need, customer PII ingested from channels into long-lived tables without a retention rule. **Add:** *"Channel-ingested customer PII is minimized, retained per the marketplace's developer policy, and excluded from default exports unless the tenant opts in."* (Shopify in particular requires purging customer data on request — this needs a home; propose it as a channels-module rule under AD-11's secret-rotation sibling.)

---

## 6. GST / e-way data residency — pinned as an ASSUMPTION where the PRD treats it as a constraint — MEDIUM

- The spine pins AWS ap-south-1 with `[ASSUMPTION: … PRD OQ6 leaves India-region as preference]`. The PRD's Constraints section says "India data residency preferred for GST-adjacent data (OQ6)" and OQ6 is open. The problem is asymmetric risk: GST invoices and e-way data have a legal residency/retention dimension; if a launch-region decision is deferred until after FR-26 builds, it hard-forks later. The spine already pins *something* (region + AWS classes) — it should pin residency as a **release-gating decision** rather than an assumption: *"GST/e-way/invoice data and the audit chain (AD-12) are stored in an India region from day one; if OQ6 resolves otherwise, the compliance module's storage is the only thing that moves."* Also worth stating: e-way thresholds must come from a config/metadata source with a tracked regulatory-watch process (the PRD explicitly demands "not hardcoded constants") — currently nothing in the spine says where regulatory parameters live (they are per-tenant customization candidates under the conventions' "metadata tables" rule; make that explicit).

---

## 7. Scan-event / audit integrity on the offline replay path — partially covered; forgery and time are not — MEDIUM–HIGH

AD-4 + AD-5 + AD-10 together get you: idempotent replay, ordered per task, server-side re-validation of business rules, conflict escalation. Three integrity gaps remain:

- **S-11. Client-forged events.** Everything the device queues is trusted client-side data. A tampered client (or a malicious employee with a modified build) can enqueue events that were never scanned — the server re-validates business rules but nothing authenticates the *device or its claims*. Mitigation is proportionate for v1: device enrollment (S-4), replay-time re-authorization (S-8), server-side plausibility checks (task assignment matches actor, bin exists in the tenant, qty within sane bounds), and rate/anomaly monitoring per device. Full remote attestation is a v2+ note. **Add to AD-4:** *"Replayed items are validated for actor-task assignment, tenant/bin plausibility, and per-device anomaly thresholds; failures quarantine to review, never auto-apply."*
- **S-12. Event time vs replay time.** The ledger event carries actor + timestamp (FR-4). Offline, device clocks drift and the *ledger write* happens at replay time. The spine must state the rule: events carry both `occurred_at` (device-supplied, untrusted, for floor-process ordering) and `recorded_at` (server, authoritative for audit/retention); audit ordering and FR-28 use `recorded_at`, dock-to-stock etc. use `occurred_at` with a recorded drift guard. Silent omission here corrupts KPIs (FR-27) and makes the audit trail's chronology unreliable.
- **S-13. Inbound webhook/callback authenticity.** AD-5 makes webhook consumers idempotent but says nothing about *authenticating* them. Shopify/Amazon/Flipkart webhooks carry HMAC signatures; carrier callbacks vary; a forged dispatch/tracking callback is a state-changing write into AD-10's command layer. **Add to AD-5:** *"Every inbound webhook verifies platform-specific signature/allowlist (HMAC, signed payload, IP allowlist) before idempotency processing; unverified payloads are rejected and logged, and verification is enforced at the port/controller layer, not in module logic."*

---

## 8. Rate limiting / sync-storm circuit breaking (PRD cost guardrail) — not an invariant; it is forgotten — HIGH

The PRD's Constraints section is explicit: *"channel-sync and carrier-API call volumes are metered per tenant; runaway integration loops (sync storms) circuit-break automatically."* The spine has **no rule** for this. NFR-4's "noisy-neighbor load-shedding protects interactive scanning paths over background sync" gestures at it, but load-shedding ≠ metering, and neither says who pulls the plug on a sync storm. This matters more than it looks: a channel-sync bug or a carrier-API retry loop (AD-7 retries with backoff, unbounded by anything) can generate runaway billable API calls against per-tenant quotas — an availability, cost, and marketplace-terms problem at once. It must be an invariant with teeth, same register as AD-1/AD-2.

- **Proposed new invariant AD-13 — Per-tenant integration budgets with automatic circuit breaking `[NEW — ADOPT before FR-24/FR-17 builds]`:**
  - *Binds:* channels, carriers, notifications modules, `jobs/` scheduler, API edge.
  - *Rule:* every outbound integration call (channel availability sync, order ingest, carrier rating/label, e-way) is metered per tenant per integration with configurable budgets (per-minute, per-hour, per-day). Budget breach opens a circuit: sync pauses with an operator-visible degraded state (same "queue depth, not error" philosophy as AD-4), an alert fires, and domain state is unaffected — availability sync pausing never falsifies ATP (ATP stays ledger-derived; channels just go stale with a staleness indicator, per FR-24/25 targets). Circuit-breaker state and meter totals are themselves projections with the same reconciliation discipline as AD-1. Inbound API/webhook paths get per-tenant rate limits at the edge with NFR-4's priority order: interactive scanning > interactive web > background sync. No code path may call a third-party API outside the metered adapter ports (AD-6 gives this teeth: only the channels/carriers/compliance adapters can egress).

---

## 9. Minor / hygiene — LOW

- **S-14. Structured logs contain no PII rule.** The convention mandates `tenant_id/warehouse_id/request_id` on every line; add a companion rule: no PII, no integration credentials, no customer identifiers in logs (see S-10, AD-11).
- **S-15. Problem-details error envelopes** (RFC 9457) should be stated to exclude internal identifiers/stack traces and to be tenant-agnostic-safe — trivial, but it is the one place cross-tenant leakage routinely happens by accident (verbose 500s leaking another tenant's ids).
- **S-16. Presigned-URL hygiene for exports** covered in S-3; also ensure carrier labels/packing slips (potentially PII-bearing) stored in S3 follow the same per-tenant prefix + short-TTL access pattern.
- **S-17. FR-26 retry payloads** (e-way/GSP) persist compliance documents; state that invoice/e-way artifacts are tenant-scoped rows with the same AD-3 scoping and AD-12 retention — currently only the *port* (`EwayGateway`) is named, not the storage.

---

## Summary of proposed spine changes

| # | Change | Type | Severity | Where |
| --- | --- | --- | --- | --- |
| S-1 | Tenant context mandatory for every execution context; RLS-exempt role list as reviewed constant; RLS-enforcement CI test | Tighten AD-3 | HIGH | AD-3 |
| S-2 | `SET LOCAL` per-transaction tenant context, transaction pooling discipline | Tighten AD-3 | MEDIUM | AD-3 |
| S-3 | Export scoping, per-tenant prefixes, short-TTL, single-access logging | New rule (fold into AD-12) | HIGH | AD-3/AD-12 |
| S-4 | Mobile store encryption, device enrollment/revocation, wipe, cache scope limits | Tighten AD-4 | HIGH | AD-4 |
| S-5 | Valkey key namespacing + in-script tenant validation | Tighten AD-2 | MEDIUM | AD-2 |
| S-6 | Tokens authenticate, authorize at command entry; role epoch; ≤15 min; audit role changes | Tighten AD-10 + conventions | HIGH | AD-10 |
| S-7 | Refresh rotation + reuse detection, session revocation, device-bound sessions, Owner MFA decision | New rule | HIGH | conventions |
| S-8 | Replay-time re-authorization of actor/device/task; quarantine on failure | Tighten AD-4/AD-10 | HIGH | AD-4, AD-10 |
| S-9 | Tamper-evident hash-chained ledger/audit, WORM anchor, 7-yr lifecycle with restore verification, tamper-evident export digests | New AD-12 | HIGH | new |
| S-10 | PII minimization in audit, DPDP position, offboarding retention split | New rule | MEDIUM | AD-12 / conventions |
| S-11 | Replay plausibility validation + per-device anomaly thresholds | Tighten AD-4 | MEDIUM | AD-4 |
| S-12 | `occurred_at` (device, untrusted) vs `recorded_at` (server, authoritative) rule | New convention | MEDIUM | AD-9/AD-4 |
| S-13 | Inbound webhook signature verification before idempotency | Tighten AD-5 | MEDIUM | AD-5 |
| AD-11 | Tenant-scoped, KMS-envelope-encrypted, rotatable, auditable third-party secrets; deletion on disconnect/offboard | New invariant | **CRITICAL** | new |
| AD-13 | Per-tenant integration budgets + automatic circuit breaking; staleness indicator; egress only via adapter ports | New invariant | HIGH | new |
| S-14/15/16/17 | Log PII rule; problem-details hygiene; export/label presign hygiene; FR-26 artifact scoping | Hygiene | LOW | conventions |

**Adoption-order recommendation:** AD-11 (secrets) and the AD-3 scoping tightening first — both gate the channels module (FR-24/25), which is on the critical path and is where all three CRITICAL/HIGH credential and isolation risks concentrate. AD-13 must land before availability sync goes live, not after. AD-12 before FR-28's export code exists (retrofitting tamper-evidence onto a live audit store is painful; starting with it is free).