---
title: 'Ledger anchoring and chain alerts — the hash chain is verified and anchored on a schedule, copied to WORM storage, a break alerts the Owner, and an anchored range downloads as a verifiable proof'
type: 'feature'
created: '2026-10-14'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-9-context.md'
  - '_bmad-output/implementation-artifacts/spec-9-3b-async-audit-export.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/modules/inventory.md'
  - 'docs/design/modules/notifications.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** AD-16 and story 9.3 require three things, and none of them happens today:
- the ledger's hash chain is anchored periodically to WORM storage;
- a chain break is a severity-1 alert;
- digest exports can be produced against the anchor.

`verifyChain`, `anchorChain` and `exportDigest` exist (`ledger.service.ts`), but only tests call them. Anchors live only in Postgres, and nothing subscribes to `ledger.chain_broken`. Migration 0026 multiplied every older event's `quantity_delta` by 1000 without rehashing, so a naive scheduled check would alert on those events forever.

**Approach:**
- **The worker.** An env-gated worker runs per warehouse:
  - it finds the pre-0026 prefix once and verifies it in its original form;
  - it anchors new events in bounded chunks;
  - it re-verifies anchored ranges in rotation;
  - it copies anchors to S3 Object Lock behind an env-switched store.
- **The alert.** A break becomes one owner panel entry, which stays open until an owner acknowledges it.
- **The web.** A "Ledger integrity" section on `/reports` shows the status and downloads a proof file for any anchor.

**Decisions (human, 2026-10-14):**
1. **Legacy events are verified in their pre-0026 form.** This amends the first answer, "seal a baseline", after design review K8.
   - **What 0026 changed.** 0026 only scaled `quantity_delta` by 1000. So an event written before it reproduces its stored hash when `quantityDelta / 1000` is hashed.
   - **The baseline.** On a warehouse's first run, the boundary `B` is recorded. Events at or below `B` are verified in that form, and an edited legacy event is a break.
   - **The view** reads "N events verified in the pre-0026 form".
2. **WORM storage is a port, switched by an env var, with S3.**
   - Anchors commit to Postgres as they do now. A worker then copies each anchor to S3 with Object Lock (COMPLIANCE mode, ap-south-1) and records the object version.
   - The switch is `LEDGER_ANCHOR_WORM=none` (the default, for dev and CI) or `s3`.
   - The S3 adapter is tested against a mocked client. Going live needs a bucket with Object Lock and credentials, which the docs describe.
3. **The alert is an owner panel entry with acknowledge.**
   - It is a new owner-only source: one entry per break, not one per check run, and never pushed.
   - The error log stays loud.
   - The entry stays open until an owner acknowledges it. Detection never auto-heals.
4. **The digest export is a Ledger integrity section** on `/reports`, owner-only (`audit.view`).
   - **Per warehouse:** the verified position, the last anchor and its WORM reference, and any break.
   - **"Download proof"** gives a JSON file for one anchored range, holding:
     - its `seq:eventHash` lines;
     - the digest;
     - the anchor;
     - the S3 key, version and retain-until date;
     - how to recompute the digest.

## Boundaries & Constraints

**Always:**

- **Inventory owns all of it.** The ledger is inventory's, so the new tables are written only by inventory, pinned by an ownership block in `architecture.spec.ts`. Routes go through `InventoryFacade`.
- **Legacy form.**
  - `legacyEventHashOf(row)` is `eventHashOf({...row, quantityDelta: row.quantityDelta / 1000})`. It applies only when `quantityDelta % 1000 === 0`; otherwise it returns no match.
  - `verifyChainInTx` gains an optional `legacyThroughSeq` (default 0). An event with `seq ≤ legacyThroughSeq` passes when **either** form reproduces its stored hash. A zero-delta event hashes identically in both forms.
  - Linkage (`prev_hash`) is checked for every event as today.
  - `verifyChain`, `anchorChain` and the re-verify read `legacyThroughSeq` from `ledger_integrity_state` (0 when absent). So an un-baselined warehouse still reads its pre-0026 events as broken, and `fractional-quantity.spec.ts:390` keeps its pin.
- **Fold PENDING a14.** `verifyChain` validates its range: `fromSeq ≥ 1`, integers, and `toSeq ≥ fromSeq` when given. Anything else is 400 `validation-failed`, and no break is recorded.
- **Migration 0071** (§3 checklist; the probe DO-block covers every new CHECK) adds:
  - **`ledger_anchors.kind`:** `text NOT NULL DEFAULT 'verified'`, CHECK `verified|legacy`. The constant default is PG11+ fast-default, with no rewrite and no row trigger. `legacy` means "verified in the pre-0026 form".
  - **`ledger_integrity_state`** (RLS), PK `(tenant_id, warehouse_id)`:
    - `legacy_through_seq int NOT NULL`;
    - `baselined_at`;
    - `verified_through_seq int`, `verified_at`;
    - `broken_at_seq int`, `broken_detected_at` (the lowest break seq detected, and when it was first detected; set on detection, **never cleared**: detection never auto-heals);
    - `reverify_after_seq int NOT NULL DEFAULT 0`;
    - `last_run_at`, `created_at`, `updated_at`.
  - **`ledger_chain_breaks`** (RLS):
    - `id`, `tenant_id`, `warehouse_id`;
    - `kind` (CHECK `chain|worm`);
    - `first_seq`;
    - `anchor_id` (null for `chain`);
    - `reason`;
    - `detected_by` (CHECK `anchor|reverify|verify`);
    - `detected_at`, `acknowledged_by`, `acknowledged_at`.

    Unique on `(tenant_id, warehouse_id, kind, first_seq)`. Shape CHECKs: the two acknowledgement columns are both null or both set; `kind = 'worm'` ⇔ `anchor_id IS NOT NULL`.
  - **`ledger_anchor_worm_copies`** (RLS, no FK):
    - `anchor_id` PK, `tenant_id`;
    - `bucket`, `object_key`, `version_id`;
    - `retain_until`, `copied_at`.

    The 0006 append-only trigger pattern (UPDATE/DELETE plus TRUNCATE) is applied to it.
  - **The source CHECK** is widened with `ledger-chain-break` (the 0070 drop/re-add).
- **The worker.** `LedgerIntegrityWorker` in `jobs/jobs.module.ts` runs when `LEDGER_INTEGRITY_POLL_MS` is set (recommended `3600000`).
  - **Shape:** the `StorageSnapshotWorker` shape. It finds tenants through `AUTH_DATABASE` and warehouses through a facade list. A rotating window caps each tick at `MAX_LEDGER_INTEGRITY_SCOPES_PER_TICK` (default 50). Each warehouse runs in its own `try/catch`, and `tick(nowMs)` is public.
  - **Per warehouse,** it calls `InventoryFacade.runLedgerIntegrity(tenantId, warehouseId)`. Steps 2, 3 and 4 run **independently**, each in its own `try/catch`. Only step 2 stops on a break.
  1. **Baseline** (once, when no state row exists).
     - **Find `B`.** A chunked scan (1,000 rows, outside the lock) finds `B`: the largest `s` such that every event in `[1..s]` matches `legacyEventHashOf` and links correctly. The scan stops at the first event that does not.
     - **Commit it.** Then, **under `warehouseAdvisoryLock` in one transaction:**
       1. re-check that no state row exists;
       2. take `latest()` (an anchor from before this story, possible on dev databases);
       3. set `legacy_through_seq = B`;
       4. when `B ≥ 1` and no anchor exists, commit `legacy` anchors over `[1..B]` in chunks of `LEDGER_ANCHOR_MAX_RANGE` (digest over the stored hashes);
       5. insert the state row with `ON CONFLICT DO NOTHING`.
     - **Existing anchors.** When anchors already exist, no legacy anchors are written, and their ranges re-verify with `legacyThroughSeq = B`.
     - **Empty warehouse:** a state row with `B = 0`.
  2. **Anchor the tail, bounded.** Call `anchorChain(t, w, latest.toSeq + LEDGER_ANCHOR_MAX_RANGE)` (default 10,000) up to `LEDGER_ANCHOR_CHUNKS_PER_TICK` (default 10) times. Then:
     - **Nothing new:** the two refusals ("Nothing to anchor", "Nothing new to anchor") are no-ops. `anchorChain` now returns a typed `{ nothing: true }` instead of a 422 for them, so no status matching is needed.
     - **A seq gap** (a deleted event) becomes a `ChainBreakReport` (reason `missing events …`, `first_seq` = the first missing seq), not a 422.
     - **Success** sets `verified_through_seq`, `verified_at` and `last_run_at`. It never touches `broken_*`.
     - **A break** is recorded (below), and the step stops.
  3. **Re-verify one anchored range.**
     - **Which range:** the next anchor with `to_seq > reverify_after_seq`, wrapping; the cursor advances to its `to_seq`.
     - **The checks:** recompute with `legacyThroughSeq`, and require the anchor's digest (a `chain` break, `detected_by: reverify`).
     - **With `s3` and the anchor copied:** read the object back through the port and compare its digest.
       - A network error or 5xx is logged and retried next tick; it is never a break.
       - `NoSuchKey`/`NoSuchVersion`, or a different digest, is a `worm` break (`first_seq` = the anchor's `from_seq`, `anchor_id` set).
  4. **Copy to WORM** (`s3` only). For each anchor of this warehouse with no copy row, oldest first, at most 20 per tick: `wormStore.put(anchor)`, then insert the copy row with `ON CONFLICT (anchor_id) DO NOTHING`.
     - **When two instances race,** the first committed copy row wins; the other S3 version stays orphaned and harmless.
     - **A put failure** (including a bucket without Object Lock) is logged with its error code and retried. The anchor counts in `wormPending`.
- **Recording a break,** in one tenant transaction:
  1. insert the `ledger_chain_breaks` row with `ON CONFLICT DO NOTHING`, and set `ledger_integrity_state.broken_at_seq = least(existing, first_seq)` (stamping `broken_detected_at` when it changes);
  2. **only when the row is new,** append `ledger.chain_broken` and log `SEVERITY-1`. A re-detection logs WARN only.
  - **The payload keeps its existing keys** `{warehouseId, fromSeq, toSeq, reason}` and adds `{breakId, kind, detectedBy}`. Pins are updated by addition only, and the log format `seq=<from>..<to>` is kept.
  - **`verifyChain`'s and `anchorChain`'s own alert paths** go through this path, and their append failure still propagates.
  - **The event names** `ledger.chain_broken` and `ledger.chain_break_acknowledged` become exported constants, and notifications pins its own copy of each string.
- **The WORM port.** `LedgerAnchorWormStore`, token `LEDGER_ANCHOR_WORM_STORE`, bound by `ledgerAnchorWormFromEnv` (the `pushGatewayFromEnv` precedent). A missing bucket, a bad region or a bad retention value fails boot; Object Lock itself can only be discovered at the first put.
  - **Interface:** `put(anchor) → {bucket, objectKey, versionId, retainUntil}`; `get(ref) → {digest, fromSeq, toSeq} | 'missing'`; transport errors throw.
  - **`s3`** uses `@aws-sdk/client-s3`, pinned, with `PutObject`:
    - `ObjectLockMode: 'COMPLIANCE'`;
    - `ObjectLockRetainUntilDate = anchoredAt + LEDGER_ANCHOR_RETENTION_DAYS` (default 2,557, 7 years);
    - `ChecksumAlgorithm: 'SHA256'`, which satisfies Object Lock's integrity-header requirement.
  - **Key:** `ledger-anchors/<tenant>/<warehouse>/<toSeq padded to 12>-<anchorId>.json`. The body is the anchor (with `kind`) as canonical JSON.
  - **Env:** `LEDGER_ANCHOR_S3_BUCKET`, and `AWS_REGION` (default `ap-south-1`). Credentials come from the SDK default chain.
  - **IAM:** `s3:PutObject`, `s3:PutObjectRetention`, `s3:GetObject`, `s3:GetObjectVersion`.
- **The notification source `ledger-chain-break`.**
  - It is added to the tuple, the CHECK, the DTO union, and `SOURCE_RESOLUTIONS: ['acknowledged']`.
  - **Audience:** `SOURCE_AUDIENCE: { capability: 'ledger.acknowledge' }`, the capability of the command that resolves it.
  - **Never pushed.**
  - **Raise** on `ledger.chain_broken`: `sourceId = breakId`, the warehouse, summary `{kind, firstSeq, reason, detectedBy}`.
  - **Resolve** on `ledger.chain_break_acknowledged` (`{breakId, warehouseId}`).
- **Acknowledge.** `POST /tenants/{t}/warehouses/{w}/inventory/ledger/breaks/{breakId}/acknowledge`, §1 skeleton.
  - **Capability:** a new owner-only `ledger.acknowledge`, the 43rd. The owner gets it automatically. The web adds it to `CAPABILITIES` and `OWNER_ONLY_CAPABILITIES`; pins move 42 → 43.
  - **Order:** lock the break row `FOR UPDATE` and replay under the lock. The hash carries `arm: 'ledger-break-ack'`. There is a same-key race test.
  - **Refusals:** an unknown id, or one in another warehouse → 404 `chain-break-not-found`. Already acknowledged → 409 `chain-break-acknowledged`.
  - **Writes:** the acknowledgement; the audit row `ledger_chain_break.acknowledged` (target `ledger_chain_break`, added to `AUDIT_TARGET_TYPES` and `AUDIT_NEW_ACTIONS` with `expectAuditRow`); `ledger.chain_break_acknowledged`. The answer is 200 `ChainBreakDto`.
  - **Acknowledging repairs nothing.** `broken_at_seq` and the halted anchoring are unchanged.
- **The reads.** Each is `audit.view`-gated through the facade's `getMemberRoleIn` + `assertPermission` in its own transaction. That makes three more named gated reads.
  - **`GET /tenants/{t}/inventory/ledger/integrity`** is unpaged, bounded by the warehouse count; this is a documented exception. Each row:
    - `{warehouseId, warehouseCode, baselined, legacyThroughSeq, verifiedThroughSeq, verifiedAt, lastRunAt}`;
    - `brokenAtSeq` and `brokenDetectedAt`;
    - `lastAnchor: LedgerAnchorDto | null`;
    - `wormPending`;
    - `breaks: ChainBreakDto[]`, open and acknowledged, newest first, at most 10.

    The top level adds `wormStore: 'none'|'s3'`.
  - **`LedgerAnchorDto`** is `{id, kind, fromSeq, toSeq, digest, anchoredAt, worm: {bucket, objectKey, versionId, retainUntil, copiedAt} | null}`.
  - **`ChainBreakDto`** is `{id, kind, firstSeq, anchorId, reason, detectedBy, detectedAt, acknowledgedBy, acknowledgedAt}`.
  - **`GET /tenants/{t}/warehouses/{w}/inventory/ledger/anchors`** takes `?cursor&limit`: `limit` 1–200, default 50, ordered `to_seq DESC`. The cursor encodes `to_seq`; a bad one is 400 `invalid-cursor`.
  - **`GET /tenants/{t}/warehouses/{w}/inventory/ledger/anchors/{anchorId}/proof`** returns `{tenantId, warehouseId, anchor: LedgerAnchorDto, algorithm, legacyForm, lines, recomputedDigest, matches}`.
    - `algorithm`: "sha256 over the '\n'-joined 'seq:eventHash' lines, seq ascending, no trailing newline".
    - `legacyForm` explains the ÷1000 rule for a `legacy` anchor.
    - Its size is bounded by `LEDGER_ANCHOR_MAX_RANGE`.
    - An unknown anchor is 404 `anchor-not-found`.
- **The web: the Ledger integrity section** (`components/reports/ledger-integrity.tsx`, words in `lib/ledger-integrity.ts`).
  - **Placement:** on `/reports` after Audit, rendered only with `audit.view`.
  - **The anchor:** `LEDGER_INTEGRITY_ANCHOR = 'ledger-integrity'` is an always-rendered wrapper around the loading and failure states too.
  - **The refresh event:** `LEDGER_INTEGRITY_REFRESH_EVENT`, sent from a `notification-entry.tsx` branch, with reload and scroll on mount, on `hashchange` and on that event (the 9-3b pattern).
  - **Per warehouse** (label from `warehouseCode`):
    - **Status, in priority order:**
      1. "Broken at #N" (red text plus the word, never colour alone), with "· acknowledged" once every break is acknowledged;
      2. "Verified through #N · <IST>" (`istDateTimeLabel`);
      3. "Not yet checked".
    - "N events verified in the pre-0026 form" when `legacyThroughSeq > 0`.
    - The last anchor's range and time.
    - **WORM:** "Stored in WORM until <date>", "N anchors waiting for WORM copy", or "WORM storage not configured".
  - **Breaks** show their kind, first seq, reason and time. **Acknowledge** shows only with `ledger.acknowledge`; it uses a key per click and a synchronous-ref double-click guard. A 409 `chain-break-acknowledged` reloads silently. The section reloads after an acknowledge.
  - **Anchors** is an expandable paged list with **Download proof**: a `parseAs: 'blob'` fetch, saved with `downloadBlob` as `ledger-proof-<warehouseCode>-<fromSeq>-<toSeq>.json`.
  - **States and copy:**
    - Refresh is manual; there is no polling.
    - An empty tenant reads "No warehouses yet".
    - `role-denied` hides the section.
    - `integrityReason` maps `chain-break-not-found`, `anchor-not-found`, `invalid-cursor` and `validation-failed`.
- **The web: notifications.** `ledger-chain-break` joins `KNOWN_SOURCE_TYPES`:
  - category "Ledger integrity";
  - "Ledger chain broken at #N — <warehouse>", using the existing warehouse lookup; a `worm` break reads "WORM copy mismatch at #N — <warehouse>";
  - href `/reports#ledger-integrity`.

**Never:**
- **No change to ledger history:** no rehashing of legacy events and no editing of the ledger. Acknowledging repairs nothing.
- **No recovery path:** no re-baseline of a broken chain and no auto-heal. A broken warehouse stops anchoring until someone investigates (PENDING).
- **No new S3 surfaces:** no signed URLs and no S3 read path for downloads. The proof is served from Postgres plus the copy row.
- **No infrastructure in the repo:** no IaC, bucket creation or credentials. The docs say what to provision.
- **Out of scope:**
  - any change to the 9-3b export store;
  - a retention lifecycle (9-3d);
  - push for the new source;
  - portal access.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Clean warehouse | 10 events, tick | State `B = 0`; one `verified` anchor 1..10; `verified_through_seq` 10 | — |
| Legacy prefix | Events 1..5 rewritten as 0026 did (`quantity_delta × 1000` under `session_replication_role = replica`, hashes untouched); 6..9 normal | `B = 5`; `legacy` anchor 1..5; `verified` anchor 6..9; no break; the view reads "5 events verified in the pre-0026 form" | — |
| Edited legacy event | As above, then event 3 edited | A break at #3, not a legacy match | — |
| Bounded anchoring | 25 events, `MAX_RANGE` 10, `CHUNKS` 2 | Anchors 1..10 and 11..20 this tick; 21..25 next tick | — |
| Tail tamper | An unanchored event edited | One break, one event, one owner entry; no anchor; status "Broken at #N" | — |
| Deleted event | An unanchored event deleted | One break (`missing events`), one entry | — |
| Re-detection | The same break on the next tick | No new row, event or entry; WARN only | — |
| Anchored-range tamper | An anchored event edited | The rotation finds it (`reverify`). The tail keeps anchoring, and the status stays "Broken at #N" (never cleared) | — |
| Acknowledged break | Owner acknowledges, then the next tick runs | Entry resolved `acknowledged`; audited; status "Broken at #N · acknowledged"; no new alert | Replay → same 200; second key → 409; ops_manager → 403 |
| Baseline race | Two concurrent baselines | One state row; no duplicate legacy anchor | — |
| WORM copy | `s3` with a fake store | `put` called; copy row written; mocked SDK sees COMPLIANCE, retain-until and SHA256 | Put failure → no row, `wormPending` counts it, retried |
| WORM mismatch / missing | The fake returns another digest / `'missing'` | One `worm` break with the anchor id | Transport error → logged, no break |
| Proof | Any anchor | `lines` recompute to `digest`; `matches: true`; `worm` set once copied | Unknown → 404 |
| Gated reads | ops_manager reads | 403 `role-denied` | — |
| Bad verify range | `verifyChain(t, w, 0)` | 400; no break row | — |
| Worker off | `LEDGER_INTEGRITY_POLL_MS` unset | Nothing runs; "Not yet checked" | — |
| Web | Each status in priority order; legacy copy only when `B > 0`; three WORM states; Acknowledge hidden without the capability; 409 reloads; `role-denied` hides the section; proof filename; bell href plus the refresh event; empty, loading and failure states | As specified above | — |

</frozen-after-approval>

## Code Map

Paths are under BE `workspace/core/backend/wms-be/src` and FE `workspace/core/frontend/wms-fe/src`.

- **Ledger** (`modules/inventory/ledger.service.ts`):
  - `:24` `GENESIS_PREV_HASH`
  - `:93`/`:102` the reports
  - `:142` `warehouseAdvisoryLock`
  - `:189-226` `canonicalEventBytes` (`quantityDelta` is a JSON number)
  - `:243` `eventHashOf`
  - `:273` `digestOverRange`
  - `:441` the store
  - `:885` `verifyChain` (its alert at `:903-907`)
  - `:933` `anchorChain`: `uptoSeq` at `:936`; the lock at `:950`; refusals at `:960-966` (nothing), `:973-978` (nothing new), `:984-999` (gap, checked before verify); the alert at `:1021-1025`
  - `:1045` `exportDigest`
  - `:1711` `verifyChainInTx`: the whole range in memory at `:1726`; a gap only with `toSeq` at `:1734-1743`; a mid-chain start at `:1751`; break reasons at `:1811-1823`
- **Store seam:** `modules/inventory/anchor-store.ts:9-42`, bound at `inventory.module.ts:41`. `latest()` orders by `to_seq DESC`.
- **Schema:** `shared/db/schema.ts:10` `appMetadata`, `:1276` `ledgerAnchors` (unique `(tenant, warehouse, to_seq)` at `:1293`).
- **DDL:** `drizzle/0006_curvy_nehzno.sql:73-107` (RLS, `ledger_append_only_guard`); `drizzle/0070_*` (the source CHECK, probe shape).
- **Facade:** `modules/inventory/inventory.facade.ts:~696-719` (passthroughs).
- **Gated-read pattern:** `modules/reporting/reporting.facade.ts:261` (imports `getMemberRoleIn` from `tenancy.service`).
- **Chain tests:**
  - `test/ledger.spec.ts:482,524,553,574,915,938`
  - `test/reconciliation.spec.ts:863` (the replica-role tamper), `:888-897` (the payload `toEqual`, updated by addition)
  - `test/fractional-quantity.spec.ts:390` (keeps its pin)
  - `test/reporting.spec.ts:1225` (the replica-role pattern)
  - **Do not** use `verifyPreMigrationChain`: it runs a separate 0025-era database. Build the legacy fixture as the matrix says.
- **Jobs:**
  - `jobs/jobs.module.ts:842` `StorageSnapshotWorker` (tenants `:44`, window `:94`, `tick`)
  - `:970` `parsePollMs`
  - Test the window and the per-scope catch with a fake facade (`test/metering.spec.ts:1050-1068`). Drive matrix rows through `runLedgerIntegrity`, not `tick()`.
- **Env-switched port:** `modules/notifications/push-gateway.ts:21,127,185`; `notifications.module.ts:42` (`useFactory`).
- **Notifications:**
  - `notification-sources.ts`: `:23`, `:56` `SOURCE_RESOLUTIONS`, `:265`, `:552-558` (the audience rule), `:569-577`
  - `push.enqueue.ts`, `push-rules.ts`
  - `api/notifications.dto.ts`
- **Command / audit / permissions:**
  - `modules/clients/clients.command.ts:471,492,517`
  - `shared/primitives/audit.ts`
  - `test/support/audit-guard.ts`
  - `modules/tenancy/permissions.ts:13,288-289`
  - `test/users.spec.ts:885`
  - race test pattern: `test/inbound.spec.ts` (`raceTwice` + `waitParked`)
- **Routes:**
  - `api/inventory.controller.ts:71` (`@Controller('tenants')`), `:282` (`invalid-cursor`), `:607` (the warehouse-scoped inventory prefix)
- **FE:**
  - `app/(app)/reports/page.tsx:22`
  - `components/reports/audit-trail.tsx:57` (the gate)
  - `components/reports/audit-exports.tsx:182` (the anchor wrapper)
  - `lib/audit-exports.ts:82` `istDateTimeLabel`, `requestAuditExportsRefresh`
  - `components/notifications/notification-entry.tsx:43`
  - `lib/notifications.ts:28-38,68-71` (warehouse lookup), `:73-95,186,249`
  - `lib/users.ts:205` (`OWNER_ONLY_CAPABILITIES`); `lib/users.test.ts:57`
  - `lib/csv.ts:47` `downloadBlob`
  - `lib/api/client.ts:1226` (the blob wrapper)
  - `isExportRoleDenied` (`lib/audit-exports.ts`) as the role-denied precedent

## Tasks & Acceptance

**Execution:**
- [ ] **BE migration 0071** (§3): `kind`, the three tables (RLS, CHECKs, unique, the copy table's append-only triggers), the widened source CHECK; journal, snapshot, probe.
- [ ] **BE ledger:**
  - `legacyEventHashOf`
  - `legacyThroughSeq` in `verifyChainInTx`
  - `verifyChain`'s range validation
  - `anchorChain`'s typed no-op and gap-as-break
  - the anchor `kind` through the store
  - break recording (one path for all detectors)
  - exported event constants
- [ ] **BE inventory:**
  - `runLedgerIntegrity` (baseline under the lock, bounded anchoring, rotating re-verify, WORM copy; steps independent)
  - the WORM port with `none`, `s3` and `ledgerAnchorWormFromEnv`
  - acknowledge
  - the three reads with their DTOs
  - the ownership block
- [ ] **BE deps:** `@aws-sdk/client-s3` pinned (and `aws-sdk-client-mock` dev-only, for the adapter's unit test), added with bun.
- [ ] **BE tenancy:** `ledger.acknowledge` (43); the pins.
- [ ] **BE notifications:** the source, the DTO arm, the not-pushed pin, the event-string pins.
- [ ] **BE api:** routes, DTOs, `openapi.json`.
- [ ] **BE jobs:** `LedgerIntegrityWorker`. Add `LEDGER_INTEGRITY_POLL_MS`, `LEDGER_ANCHOR_MAX_RANGE`, `LEDGER_ANCHOR_CHUNKS_PER_TICK`, `LEDGER_ANCHOR_WORM`, `LEDGER_ANCHOR_S3_BUCKET`, `AWS_REGION` and `LEDGER_ANCHOR_RETENTION_DAYS` to `.env.example` and the README, with provisioning (an Object Lock bucket in ap-south-1, the IAM actions).
- [ ] **BE tests:**
  - every BE matrix row, through `runLedgerIntegrity` with a fake WORM store
  - the adapter's unit test on the mocked SDK
  - the worker window with a fake facade
  - existing pins updated by addition only
- [ ] **FE:**
  - `api:generate`
  - the mirror (43)
  - `lib/ledger-integrity.ts` + `components/reports/ledger-integrity.tsx` + the hook
  - the bell branch
  - the notification source
  - tests for every web matrix item
- [ ] **Meta docs:**
  - `inventory.md`: the worker, the tables, the legacy form, the break path, the bounds; correct "nothing schedules verifyChain"
  - `notifications.md`
  - IMPLEMENTATION-GUIDE: §8 (the worker), and the env-switched port list
  - API-SURFACE: routes, the 43rd capability, gated reads, the unpaged exception
  - SYSTEM-DESIGN: jobs and counts
  - `frontend/SYSTEM-DESIGN.md`, and both repo contracts
  - PENDING:
    - close: "nothing schedules verifyChain"; "pre-migration hashes"; a14's range validation; the verify-gap entries this story's tests cover
    - add: no re-baseline after a break; S3 not provisioned; orphaned S3 versions from a copy race; the integrity read is unpaged

**Acceptance Criteria:**
- Given a database with a legacy prefix and the worker on, when it ticks, then each warehouse is baselined and anchored with no alert, and the integrity section shows the pre-0026 count.
- Given a tampered event, when the worker ticks twice, then exactly one owner panel entry exists. Acknowledging it resolves the entry and writes an audit row.
- Given any anchor's proof file, when an auditor recomputes sha256 over its lines, then it equals `digest`.
- Given the full BE and FE suites, lint, typecheck, build and the capability-mirror check, when run, then they pass.

## Implementation Notes

## Spec Change Log

## Review Triage Log

Design review (2026-10-14), two lenses: backend (K) and web/API/tests (W). 25 findings, merged into 18 rows below.

| # | Lens | Finding | Verdict | Disposition |
|---|---|---|---|---|
| 1 | K, W | `anchorChain` answers a seq gap with the same 422 as "nothing new", checked before verify. The spec's "422 = no-op" would hide a deleted event forever | high (verified: `ledger.service.ts:960-999`) | Fixed: typed no-op; gap → break; a deleted-event row |
| 2 | K, W | "Stops at the first break" switched off re-verify and the WORM copy. An anchored-range break never halts the tail, so the view could read "verified" and "broken" at once; an acknowledged break looked clean | high (verified: `:968-970`) | Fixed: the steps are independent; `broken_at_seq` in state; status priority; the acknowledged label; two rows |
| 3 | K, W | The first anchor after baseline is unbounded, holds the append lock, and makes a proof of hundreds of MB | high (verified: `:950`, `:1726`) | Fixed: `LEDGER_ANCHOR_MAX_RANGE` chunks via `uptoSeq`, N per tick; legacy anchors chunked too |
| 4 | K | The legacy rule rests on `created_at`, which is not hashed. "Every hash differs" ends early on zero-delta events. Old-form verification is exact | medium (verified: `:189-226`; 0026 only scales `quantity_delta`) | **Human decision (2026-10-14): verify in the pre-0026 form**; Decision 1 amended; `ledger_integrity_since` dropped |
| 5 | K | The baseline races between instances and ignores anchors that already exist | medium (verified: unique at `schema.ts:1293`) | Fixed: re-check under the lock in one transaction; existing anchors are kept and re-verified with B |
| 6 | K | WORM copy race on the copy-row PK; read-back failure semantics; `GetObjectVersion` missing; WORM and chain breaks share a key | medium | Fixed: `ON CONFLICT DO NOTHING`; `'missing'` vs transport errors; the IAM list; the break `kind` in the unique key |
| 7 | K, W | `verifyPreMigrationChain` cannot build the legacy row: it runs a separate 0025 database | medium (verified: `fractional-quantity.spec.ts:233`) | Fixed: the fixture is described in the matrix (replica-role ×1000) |
| 8 | K, W | The payload was renamed as a side effect (`fromSeq` → `firstSeq`), and its pins are `toEqual` | low (verified: `reconciliation.spec.ts:891`) | Fixed: existing keys kept; additions only; log format kept |
| 9 | K, W | The audience should be the resolving command's capability, not a role | low (verified: `notification-sources.ts:552-558`) | Fixed: `{capability: 'ledger.acknowledge'}` |
| 10 | K | `verifyChain` would now write permanent alerts from bad input (PENDING a14) | low | Fixed: range validation, 400, no break |
| 11 | K | The acknowledge hash lacks an `arm`; no race test; the copy table's "insert-only" was unenforced | low | Fixed |
| 12 | K | The SDK dependency, the checksum requirement, and what boot can validate | low | Fixed: stated |
| 13 | W | The anchors list had no response shape; there were no web matrix rows | medium | Fixed: `LedgerAnchorDto`, paging, `invalid-cursor`; a web matrix row |
| 14 | W | No warehouse code for the proof filename; the Code Map path for `warehouseDisplayLabel` was wrong | medium (verified: `lib/drill.ts:574`) | Fixed: `warehouseCode` in the row |
| 15 | W | Anchor, refresh event and double-click guard left implicit | low (verified: `audit-exports.tsx:182`, `notification-entry.tsx:43`) | Fixed: named constants, the bell branch, the guard, `istDateTimeLabel` |
| 16 | W | The unpaged read and three more gated reads; a new route prefix | low (verified: API-SURFACE:11-12, `inventory.controller.ts:607`) | Fixed: routes moved under `…/inventory/ledger/…`; documented exceptions |
| 17 | W | Driving the whole worker is fragile across tenants | low | Fixed: rows through `runLedgerIntegrity`; the window via a fake facade (`metering.spec.ts:1050`) |
| 18 | K | Proof and verify size | medium | Fixed by row 3's bound |

## Design Notes

**Why copy after commit.** `LedgerAnchorStore` runs inside the caller's transaction, and an S3 `PutObject` cannot roll back. Postgres stays the source of the anchor, and the copy is a retried side effect, recorded in an append-only table. "Waiting for WORM copy" makes the window visible.

**Why the legacy form is safe.** An event is accepted in the old form only at or below `B`, and `B` is fixed once, from a prefix that matches the old form from seq 1. Multiplying a later event's quantity by 1000 would make it match the old form, but it sits above `B` and breaks there. Inside the prefix, a second multiplication by 1000 matches neither form.

**Why rotate re-verification.** Anchoring proves only the tail at the moment it is anchored. A later edit to an anchored event is caught only by recomputing the range against the anchor. Recomputing against the WORM copy also catches a database superuser who edits both. One range per warehouse per tick, bounded by `MAX_RANGE`, caps the cost.

## Verification

**Commands** (BE runs one jest invocation at a time):
- `cd workspace/core/backend/wms-be && bun run test -- test/ledger-integrity.spec.ts` -- expected: all pass.
- `cd workspace/core/backend/wms-be && bun run test && bun run lint && bun run typecheck` -- expected: green.
- `cd workspace/core/frontend/wms-fe && bun test && bun run lint && bun run typecheck && bun run check:capability-mirror && bun run build` -- expected: green.
