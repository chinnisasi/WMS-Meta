# Rubric Review — ARCHITECTURE-SPINE.md (WMS v1 Platform)

- **Reviewer:** rubric-walker (architecture-spine review)
- **Date:** 2026-09-08
- **Under review:** `../ARCHITECTURE-SPINE.md`
- **Inputs:** `../../prds/prd-WMS-Meta-2026-09-07/prd.md`, `../../prds/prd-WMS-Meta-2026-09-07/addendum.md`
- **Verdict:** **Conditionally acceptable — architecture core is sound; one revision pass required before epic breakdown.** The AD set correctly fixes the product's real divergence points and the FR/capability coverage is complete, but the operational envelope (load testing, retention/backups/DR, alerting surface) is silently silent rather than decided or deferred, and the AD-2 reservation-durability seam is under-specified enough that two story-level implementers could diverge on it.

---

## Checklist Item 1 — Fixes the real divergence points, misses none

**Result: PASS with 2 findings (1 high, 1 medium).**

The ten ADs map to the genuine divergence surfaces of this product:

| Divergence point | Fixed by |
| --- | --- |
| Mutable quantity tables / un-replayable state | AD-1 (ledger sole truth) |
| Two channels selling the last unit | AD-2 (atomic Valkey reservation) |
| Cross-tenant reads, warehouse retrofit | AD-3 (tenant+warehouse scope) |
| Scan loss in dead zones, silent conflict resolution | AD-4 (offline outbox, no LWW) |
| Duplicate effects from webhooks/offline replay | AD-5 (idempotency by contract) |
| Distributed-monolith coupling | AD-6 (interfaces+events, dependency direction) |
| Lost/duplicated external effects | AD-7 (transactional outbox) |
| DTO drift across three repos | AD-8 (OpenAPI generated clients) |
| Float money, timezone chaos, unordered offline ids | AD-9 (integers/UTC/UUIDv7) |
| Parallel mutation paths diverging on approval gates | AD-10 (one command layer) |

This is the right list for an event-sourced multi-tenant offline-capable WMS. Misses:

### F1 [HIGH] — Reservation durability seam (AD-2) is under-specified; two implementations can diverge
AD-2 puts reservation state solely in Valkey and says "ATP state is rebuilt from the ledger on cold start and on drift." But AD-1 defines ledger events as *stock movements* — a reservation grant is a hold, not a movement. The spine never says whether (a) a reservation grant/release writes a durable non-movement record in Postgres that the rebuild reads, (b) grants are lazily persisted only at movement time (in which case a Valkey failover between grant and ledger write silently evaporates reservations and oversells — the exact failure AD-2 exists to prevent), or (c) reservations are ledger events of a distinct type that projections must treat differently from movements. Three defensible readings; story-level work could pick different ones. This is a real divergence point at the level below and the spine's flagship AD is the one carrying it. Fix: one sentence pinning the durable representation of an active reservation and the rebuild contract (e.g., "every grant/release commits a `reservation.granted`/`reservation.released` record in the same Postgres transaction that acks the Valkey script; Valkey is a cache of that state, never its only copy").

### F2 [MEDIUM] — Ledger event schema evolution is not addressed
NFR-1 mandates continuous replay-reconciliation and NFR-5 mandates 7-year retention; AD-1 makes everything a projection replayable from events. That combination makes ledger event *payload* schema stability (or explicit versioning/migration of historic events) a real divergence point: one unit may add a required field to an event type and break replay of year-old events; another may guard it. No AD or convention row covers event payload immutability/versioning. Fix: a convention line ("ledger event payloads are append-only in schema as well as value; changes add new event types or optional fields, never mutate meaning of existing ones").

Also noted (LOW): enforcement mechanism for AD-6/AD-3 is unstated (dependency-cruiser/arch-tests for module boundaries, RLS integration tests) — the rules are clear but "enforceable" would be strengthened by naming the check.

---

## Checklist Item 2 — Every AD's Rule is enforceable and actually prevents its stated divergence

**Result: PASS with 2 findings (the F1 high above, plus one medium-low).**

Walking each AD:

- **AD-1** — Enforceable (transaction discipline + continuous replay-reconciliation is itself the detector). Prevents its divergence. ✓
- **AD-2** — Mechanism (single Lua script, no second check-and-decrement, deterministic loser outcome) is enforceable and matches addendum §1.1 and PRD FR-5's "deterministic unavailable outcome." Undermined only by the durability seam (F1). Otherwise ✓
- **AD-3** — Enforceable (base-layer scope injection + RLS as defense-in-depth); matches addendum §1.2 warehouse-as-first-class-key. ✓
- **AD-4** — Matches addendum §1.3 nearly verbatim (SQLite WAL, FIFO outbox, ULID keys, task-order replay, LWW forbidden → human review, queue-depth-not-error). Consistent with AD-10's "clients mirror, never override, server rules." ✓
- **AD-5** — Enforceable as stated for our own APIs and outbox consumers.

### F3 [MEDIUM-LOW] — Inbound webhook idempotency key source unspecified
AD-5 says "every mutating API call carries an Idempotency-Key (client-generated ULID)." Carrier callbacks and channel webhooks arrive from external parties who do not send our ULIDs. The rule needs its second half pinned ("inbound webhooks derive their key from the external event/payload identity — e.g. carrier tracking-id + status timestamp — so retries de-dupe by contract too"). As written, a unit could treat inbound webhook de-dup as FR-12's channel-order concern only and leave carrier-callback replays writing duplicate dispatch updates.
- **AD-6** — Clear, and the dependency-direction graph makes inversion visible; enforcement tooling unstated (LOW, above). ✓
- **AD-7** — Matches PRD FR-17 ("label failure does not mark dispatched") and FR-26 ("e-way failure never blocks dispatch") and addendum retry semantics. ✓
- **AD-8** — Enforceable via generated-client build failure; matches the meta repo's interface-contract mechanism. ✓
- **AD-9** — Enforceable (column types + lint); consistent with GST basis points convention. ✓
- **AD-10** — Enforceable; explicitly reconciles with AD-4's on-device rules. ✓

---

## Checklist Item 3 — Nothing under Deferred could let two units diverge

**Result: FAIL — one deferred row is too broad, and two requirements were dropped without any deferral at all.**

The genuinely deferred items are safe: each defers an *implementation choice behind an already-fixed port or contract* (EwayGateway, CarrierAdapter, serial-vs-batch discriminated union, marketplace fallback, event transport with in-process bus fixed for v1, mobile scanner internals with the ≤1.5 s budget fixed). Those are proper altitude-correct deferrals. But:

### F4 [HIGH] — The "Deployment specifics" deferral swallows owned decisions, and other requirements are dropped with no deferral row at all
- **"Deployment specifics (IaC tool, CI/CD pipeline shape, observability stack)"** defers three different things, of which only IaC/CI-CD shape is legitimately platform-level. **Observability is not deferrable as a lump at this altitude**: NFR-1 requires a *continuous* replay-reconciliation job that "alerts on any projection divergence" and FR-24/FR-27 require per-channel *sync health* surfaced — an alerting/metrics surface is therefore load-bearing in the architecture, and leaving it entirely to "platform-level work" lets the reporting module, the jobs scheduler, and the channels module each invent their own health/alert representation. Decide or open-question the *surface* (e.g. OpenTelemetry + managed metrics/alerting target), defer only the specific vendor.
- **Not deferred — absent entirely:** NFR-2's "load-tested before every peak season" (a recurring operational commitment), NFR-5's "audit retention ≥ 7 years," and any statement on **backups/DR** for the ledger of record, and **database migration strategy** for an event-sourced schema. These are not silently-droppable: retention policy shapes ledger storage decisions, and migration strategy is a per-repo divergence point. See F8.
- Notably, `jobs/` in the Structural Seed does include "reconciliation (AD-1)" — so the job exists, but the alerting destination/surface and the ops envelope around it are silent.

### F5 [MEDIUM] — PRD monetization metering requirement dropped
The PRD's monetization assumption requires only that "tiering be technically meterable" (warehouse-count and order-volume axes; traceability/channel-count gates). The spine has no metering/entitlements dimension — not an AD, not a convention row, not a Deferred entry, not an open question. Feature gating per tier touches tenancy, channels, and catalog. This is an owned dimension left silent; a Deferred row ("entitlement/metering surface — decided at feature level, spine pins only that tier state is tenant metadata, never code") would close it.

### F6 [MEDIUM] — Cost-guardrail circuit breaker dropped
PRD guardrails: "runaway integration loops (sync storms) circuit-break automatically." AD-7 gives retry-with-backoff, which is the opposite half of the requirement. No AD or convention covers a circuit breaker on outbound integration volume, so the channels and carriers modules could each implement (or omit) it differently. One line under AD-7 or a convention row fixes it.

What Deferred gets right: every PRD open question that is architectural is either deferred with its fallback ratified (OQ1 carriers, OQ3 e-way, OQ5 serial) or decided-with-assumption (OQ6 → Mumbai region, tagged `[ASSUMPTION]`); OQ2's Shopify+manual fallback (addendum §5) is ratified; the rejected-for-v1 list mirrors addendum §1.4 exactly. The wms-mobile repo-registration follow-up is correctly routed to a meta-repo change.

---

## Checklist Item 4 — Named tech is verified-current (September 2026)

**Result: PASS — every risky claim spot-checked against current sources; one LOW note.**

| Claim in spine | Verified | Status |
| --- | --- | --- |
| NestJS 12.0 | NestJS v12.0.0 released 2026-08-27/28 (Trilon/GitHub) | ✅ current, weeks old. Bonus: Nest 12 ships first-class Standard Schema (`@Body({schema})` with Zod) and machine-readable error codes — directly strengthening the spine's Zod convention and RFC 9457 `code` convention. |
| Drizzle 0.45.x, "1.0 series still RC — defer" | v1.0.0-rc.4 (2026-06-27), stable line still 0.45.x | ✅ exactly right, and the explicit deferral is the correct call. |
| Expo SDK 57 / RN 0.86 | SDK 57 released 2026-06-30 with RN 0.86 | ✅ current. (Note: known Hermes/Reanimated memory increase 25–30% — relevant to the ≤1.5 s scan budget, story-level.) |
| Valkey 9.1 | GA Feb 2026, current stable | ✅ current. |
| Next.js 16.3 | 16.3.4 released 2026-08-31 | ✅ current. |
| PostgreSQL 18.6 | PG 18 line current since Sept 2025; 18.x patch series plausible-current | ✅ not independently re-verified, low risk. |
| Zod 4.x, TanStack Query 5.x, TS 5.x | consistent with current majors | ✅ |
| Node.js 22 LTS | Real: 22.x is **Maintenance** LTS (EOL 2027-04-30); 24.x is Active LTS | ✅ accurate but see F7 below. |

### F7 [LOW] — Node 22 is accurate but not the recommended greenfield target
For a from-scratch v1 build, Node 24 (Active LTS until Oct 2026, EOL 2028) is the community-recommended target; Node 22 stops receiving updates April 2027 — inside the plausible life of this v1. Not an error, but worth one line of rationale or an upgrade note. Also worth a footnote: the Drizzle community flags production-ready RLS support as a known 1.0 gap — harmless here since AD-3 puts RLS policies in SQL with Drizzle as the query layer, but worth stating so nobody assumes ORM-level RLS.

---

## Checklist Item 5 — Ratifies rather than contradicts its inputs (FR/NFR coverage audit)

**Result: PASS with drops (the high/medium findings above); zero contradictions found.**

**FR-1…FR-30:** every FR number appears in the Capability → Architecture Map and maps to a module in the Structural Seed. Spot-checks of the trickier ones: FR-9 QC hold → inbound module ✓; FR-15 short-pick re-planning → outbound ✓ (server-side, consistent with AD-4/AD-10); FR-18's two-leg correlated warehouse transfer → AD-1's in-transit-as-projection ✓; FR-22's ≤5 min alert latency → `jobs/` scheduler + notifications module ✓; FR-25's ≤10 s ingest-to-reservation → AD-2 with DB out of hot path ✓; FR-26's "e-way failure never blocks dispatch" → AD-7 explicitly ✓; FR-28's async export → outbox/exports ✓. **All 30 covered; none dropped, none contradicted.**

**Feature-area coverage (checklist item 6, audited here):** PRD §4 has 13 feature areas; the capability map has 12 rows because 4.7 (Transfers/Adjustments) and 4.8 (Cycle Counting) merge into one row (FR-18…21). All 13 areas and all FRs are present — **PASS**, with the minor note that the row count ≠ area count only by intentional merge.

**NFR-1…NFR-6 audit:**

| NFR | Covered by | Status |
| --- | --- | --- |
| NFR-1 correctness/replay | AD-1 (continuous replay-reconciliation) | ✅ full |
| NFR-2 peak-load | AD-2 (mechanics, binds NFR-2) | ⚠️ partial — the "load-tested before every peak season" operational commitment is nowhere (→ F4) |
| NFR-3 offline | AD-4 | ✅ full |
| NFR-4 isolation | AD-3 | ⚠️ partial — the load-shedding priority clause ("scanning over background sync") is dropped (→ F8) |
| NFR-5 auditability | AD-10 (audit written) | ⚠️ partial — "retention ≥ 7 years" nowhere (→ F4) |
| NFR-6 latency budgets | Deferred text pins ≤1.5 s scan budget | ⚠️ partial — web <2 s, sync ≤60 s, label ≤5 s not carried into any convention (→ F9, LOW) |

**Ratification of addendum:** §1.1 → AD-1/AD-2/AD-5 ✓; §1.2 → AD-3 + config-as-metadata convention (explicitly cited) ✓; §1.3 → AD-4 ✓; §1.4 → Deferred rejected-list ✓. PRD assumptions (blind receiving, nightly slotting, camera scanning, carrier set) all land at the right altitude. **No quiet contradiction found anywhere** — the drops are omissions, not reversals.

### F8 [MEDIUM] — NFR-4's load-shedding priority dropped
"Noisy-neighbor load-shedding protects interactive scanning paths over background sync" appears in the PRD and addendum §1.2 (deferred only the *compute isolation beyond* load-shedding priority) but has no home in the spine. Availability-sync jobs (channels), reconciliation, and exports could each get different priority treatment. One convention row ("background jobs carry a priority class; scanning-path requests shed last") fixes it.

### F9 [LOW] — NFR-6 budgets other than the scan budget not restated
The spine pins ≤1.5 s (in Deferred prose) but web <2 s / sync ≤60 s / label ≤5 s live only in the PRD. Since AD-2/AD-7 are what make them achievable, a single conventions line carrying the four budgets would keep the level below from re-litigating them. LOW because they remain testable per-FR regardless.

### F10 [LOW] — Regulatory-watch surface for e-way thresholds
PRD constraint: e-way thresholds "current with regulation... not hardcoded constants." Spine stores GST rates as basis points and config-as-metadata covers per-tenant values, but the *regulation-changes-over-time* dimension (versioned compliance constants) is unaddressed. LOW — the compliance module can own it — but worth one line.

---

## Checklist Item 6 — Covers the driving spec's capabilities (13 feature areas)

**Result: PASS.** Audited under item 5 above: all 13 PRD §4 areas appear in the capability map, every FR-1…30 is bound, and the module decomposition (tenancy, catalog, inventory, inbound, putaway, outbound, movements, replenishment, channels, compliance, reporting, carriers, notifications) covers the full surface with no orphan capability.

---

## Checklist Item 7 — Every dimension owned at this altitude is decided, deferred, or an open question

**Result: FAIL — the operational envelope has silent dimensions.** This is the spine's biggest structural weakness (root cause of F4):

| Dimension | Status |
| --- | --- |
| Design paradigm, module boundaries | ✅ decided (paradigm section, AD-6, Structural Seed) |
| Stock truth, concurrency, offline, idempotency, integration reliability | ✅ decided (AD-1/2/4/5/7) |
| API contract across repos | ✅ decided (AD-8) |
| Primitives, naming, error envelope | ✅ decided (AD-9 + conventions) |
| Auth/roles | ✅ decided (conventions row per FR-3) |
| Infra provider + region | ✅ decided-with-assumption, correctly tagged (`[ASSUMPTION: infra provider; PRD OQ6...]`) |
| Deployment & environments | ⚠️ half — region/service classes pinned; environment matrix, secrets, **DB migration strategy**, CI/CD lumped into one broad deferral (→ F4) |
| Observability | ⚠️ half — log format decided (good, with tenant/warehouse/request ids); metrics/tracing/**alerting surface** deferred as a lump despite NFR-1 depending on it (→ F4) |
| Backups / DR | ❌ **silent** — nothing. An append-only ledger of record with 7-year retention has no stated backup/retention/DR posture anywhere |
| Peak-season load testing | ❌ **silent** — NFR-2's recurring operational commitment appears in neither decided nor deferred |
| Metering/entitlements | ❌ silent (→ F5) |
| Sync-storm circuit breaker | ❌ silent (→ F6) |
| Security envelope (encryption at rest/in transit, secret management) | ❌ silent — arguably AWS-default, but a whole dimension with no row is a finding by this rubric; fold into F4's fix |
| Event transport at scale, e-way path, carrier set, serial scope, marketplace approvals, multi-region | ✅ properly deferred with fallbacks |

---

## Findings index (severity-ordered)

| # | Severity | Finding |
| --- | --- | --- |
| F1 | **HIGH** | Reservation durability seam under-specified: AD-2 rebuilds ATP "from the ledger" but no rule says what durable representation a reservation grant leaves in Postgres; Valkey-only holds can evaporate on failover (oversell), and implementers can diverge on the representation. Pin the durable grant/release record + rebuild contract in AD-2. |
| F4 | **HIGH** | Operational envelope silent or over-deferred: peak-season load testing (NFR-2), 7-year audit retention + backups/DR (NFR-5), DB migration strategy, security envelope (encryption/secrets), and the NFR-1 alerting surface are neither decided nor deferred; "Deployment specifics" deferral is too broad. Split into: decided (migration tool + strategy, alerting/observability surface class, retention policy, load-test cadence as an ops convention) vs legitimately platform-deferred (IaC tool, CI/CD shape, observability vendor). |
| F2 | MEDIUM | Ledger event *payload* schema evolution/versioning rule absent, despite replay-based NFR-1 + 7-year NFR-5 retention making it load-bearing. |
| F5 | MEDIUM | PRD monetization's "tiering technically meterable" requirement has no spine home (no AD/convention/deferred/open-question). |
| F6 | MEDIUM | Cost-guardrail circuit breaker for sync storms (PRD Constraints) dropped — AD-7's retry-with-backoff is not a circuit breaker; channels/carriers could diverge. |
| F8 | MEDIUM | NFR-4 load-shedding priority (scanning > background sync) dropped; background job priority classes unspecified. |
| F3 | MEDIUM-LOW | AD-5 inbound-webhook idempotency key derivation (carrier callbacks, channel webhooks) unspecified. |
| F9 | LOW | NFR-6 budgets other than ≤1.5 s not carried into the spine's conventions. |
| F7 | LOW | Node 22 verified but is Maintenance LTS — Node 24 is the recommended greenfield Active LTS target; note Drizzle-RLS nuance under AD-3. |
| F10 | LOW | Regulatory-watch surface for e-way threshold changes unaddressed (versioned compliance constants). |

---

## What the spine gets right (worth keeping as-is)

- The AD set is the correct divergence-point list for this product; nothing spurious, nothing missing at its own altitude except F1/F2.
- AD-4/AD-10 explicitly reconcile on-device decisions with server-rule primacy — a subtle conflict pre-empted.
- The Drizzle deferral line ("1.0 still RC") is verified exactly correct as of Sept 2026, and NestJS 12 (released Aug 2026) ships first-class Standard Schema/Zod plus machine-readable error codes that directly reinforce the spine's AD-8 and error-envelope conventions — the stack picks are not just current but mutually reinforcing.
- Every PRD open question (OQ1–OQ6) is either deferred with a ratified fallback or resolved-as-assumption with the assumption tag; no OQ was silently buried.
- FR coverage is complete and the map is checkable row-by-row; no FR dropped or contradicted.
- The `[ASSUMPTION]` on AWS ap-south-1 correctly resolves PRD OQ6 in the India-favoring direction without overstating certainty.

## Recommended fix pass (before epic breakdown)

1. Add the durable reservation-record contract to AD-2 (F1).
2. Replace the single "Deployment specifics" deferral with: decided rows for migration strategy, retention/backups, alerting-surface class, and load-test cadence; keep IaC/CI-CD-shape/observability-vendor deferred (F4).
3. Add three one-line additions: ledger event payload immutability rule (F2), load-shedding priority convention (F8), sync-storm circuit breaker (F6); plus a Deferred row for metering/entitlements (F5).
4. Carry NFR-6's four budgets into the conventions table (F9).