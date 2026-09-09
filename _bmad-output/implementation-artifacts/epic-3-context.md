# Epic 3 Context: Receiving & Putaway — The Floor's First Flow

<!-- Compiled from planning artifacts. Edit freely. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Give the floor its first working flow: Ramesh receives against POs scan-first on mobile (partial, blind, over-receipt gating, QC holds) and puts stock away with directed bin suggestions, while the Ops Manager manages bins without code changes. Receiving against a PO is deliberately the most polished flow in v1 — the single highest-leverage process per research. The mobile scan client (offline-first, camera + HID) is born here as the substrate every later task type (picks, counts, transfers) plugs into; dock-to-stock is clocked automatically and a single-SKU single-lot GRN lands in ≤ 4 scans + 1 confirm.

## Stories

- Story 3.1: PO creation and lifecycle
- Story 3.2: Mobile client substrate — enrollment, badge-in, inbox, scanning
- Story 3.3: Scan-based receiving and GRN
- Story 3.4: QC hold and release
- Story 3.5: Directed putaway
- Story 3.6: Bin administration

## Requirements & Constraints

- POs: create with vendor, lines (SKU, qty, cost, expected date); amendable before receipt; a PO line always shows ordered / received-to-date / open quantity; closing cancels or carries open quantities; attempted receipt against a closed PO is rejected naming the PO state.
- Receiving: produce a GRN per delivery by scanning SKU/barcode with quantity via stepper or scan increments. Partial GRNs leave the PO line open with correct remaining quantity. Over-receipt beyond PO open quantity creates an over-receipt event and requests Ops Manager approval mid-receive — the task continues, never hard-blocks. Blind receive (no PO) is permitted with a reason code and is flagged on the dashboard for PO-matching. GRN creation budget: ≤ 4 scans + 1 confirm for a single-SKU single-lot pallet.
- QC Hold is a bin-level quarantine state: held stock is excluded from ATP and unpickable (pick request rejected naming the hold); release records inspector, decision, and timestamp in the ledger; QC-held stock is visible on the Inbound surface with its hold reason.
- Directed putaway: system suggests a bin per GRN line (velocity class, capacity, zone rules); operator scan-confirms actual placement; suggestion ≠ actual is allowed with a recorded reason and is measurable as a report; placing into a full or blocked bin is rejected naming the capacity/block reason.
- Bin administration: create, block, merge, retire. A bin with on-hand stock cannot be deleted — only retire-after-empty; retire-with-stock is rejected naming the SKUs/quantities blocking it; blocking removes the bin from putaway suggestions and picking immediately; merging consolidates stock with correlated ledger events.
- Task inbox: assigned/pickable tasks in suggested order; a task claimed by another operator disappears within one refresh cycle; claim-lost shows "Claimed by {other} while offline" with the operator's queued lines and their disposition.
- Scanning: device camera + paired HID, Code 128, EAN-13, QR at minimum; scan-to-decision ≤ 1.5 s on a mid-range Android, on-device where network-independent; barcode values resolving to two SKUs within a tenant are prevented at catalog entry.
- Offline tolerance: work continues through connectivity loss (≥ 30 minutes, zero scan loss); force-quit loses nothing; queued work replays in task order, idempotently, exactly once.
- Device lifecycle: enrollment binds device to tenant/operator; revocation from web Settings is wipe-flagged; mid-shift revocation shows an explicit full-screen state, never a silent mass quarantine.
- Success metrics this epic drives: time-to-first-GRN ≤ 1 business day from signup; dock-to-stock median ≤ 4 clock-hours; weekly active operators ≥ 70% of seats by week 8. Scan-rejection rate is deliberately not minimized — rising rejections with rising accuracy means verification works.

## Technical Decisions

- Backend: the `inbound` module owns POs, GRN, and QC hold (FR-7…9); the `putaway` module owns directed putaway and bin operational state (FR-10/11). Both write ledger events through the Epic 2 inventory module and depend on nothing outside it.
- Bin ownership is split: tenancy owns bin master data (create/merge/retire); putaway owns bin operational state (block, putaway suggestions). Respect this boundary — blocking lives in putaway, retire-after-empty in tenancy.
- Mutation only through command services with role/approval gates (one shared command layer, role-epoch re-evaluated at command entry — JWT is transport, not authority). Over-receipt approval is a command-layer gate, not a client rule.
- Offline-first mobile (AD-4): encrypted SQLite (WAL) local store + FIFO outbox; scan decisions (accept/reject, wrong-item/wrong-bin) run on-device — only ledger persistence waits for network. Reconnect replays in task order with client-generated ULID idempotency keys; every replayed op is re-authorized server-side against the badge-in session that created it (a deactivated operator's queued actions do not apply). Conflicts are never auto-merged (no LWW); queue state is shown as depth, never as error.
- Idempotency keys (ULID) on all mutating endpoints, tenant-scoped, stored with a request-payload hash and de-duped in the same transaction as the write (AD-5).
- Offline work settles only pre-reserved task stock (AD-14) — granting new ATP or accepting fresh orders is always online. Server-side checks a per-bin `state_epoch` captured at task start; the 4-case conflict taxonomy (apply / settle / re-plan / quarantine) resolves divergence; bin on-hand never goes negative — a violating event is rejected or routed to review, not written.
- Device secrets under envelope encryption with a KMS master key; revocation deletes device credentials and makes the wiped device's cache useless (AD-15). Devices are enrolled and revocable; revocation is surfaced, not silent.
- The mobile client is capture-agnostic: camera and HID produce the same normalized scan-event shape; camera-library choice is a feature-level decision, not architecture. `wms-mobile` is its own repo (register in the repo catalog) with Expo Router screens (badge-in, inbox), an on-device scan decision engine, and an offline store/outbox/replay layer.
- API contract: wms-be OpenAPI is the single truth; web and mobile commit generated typed clients — no hand-written API types on consuming sides (AD-8). Integers for quantities (base-UoM), UTC timestamps, UUIDv7 IDs; ledger events distinguish occurred-at (device time) from recorded-at (server ingest).

## UX & Interaction Patterns

- Mobile IA: device enrollment (first run) → badge-in → task inbox with an All/Pick/Putaway/Count/Transfer switcher (in-surface, not app-level tabs) → linear per-task-type flows → sync summary screen after replay (settled / rejected / quarantined counts per task). Badge-in: offline restore from device cache after the first-ever (connectivity-required) badge-in.
- Scan banner: full-width, ≥ 96px, appears ≤ 1.5 s, state-coded by fill + glyph + word (never color-only): ✓ Accepted (server-confirmed, online) / ↻ Recorded · queued (on-device pass, persistence pending — never green while queued) / ✕ Rejected (≤ 500 ms, reason + nearest correct bin offered; rejected scans never queue) / ⚠ Held for review (server-quarantined replayed op, links to sync summary). Dark-mode banner fills always pair with their dark-foreground tokens.
- Scan is the universal verb (scan → banner → next): camera and HID interchangeable at every step; manual entry is a first-class one-tap fallback at every scan step; HID keeps the capture-field focus across banner swaps (a next scan is never silently lost) and never splices into mid-typed manual entry; buttons ≥ 48dp, glove- and one-handed-usable; swipe never destroys work.
- Qty stepper for receive: large +/-, glove-usable, scan increments where applicable, manual entry as a deliberate fallback tap.
- Task card: type icon, order/PO ref, item count, claimed-by state; optimistic claim. Queue chip (offline) is amber with a count, never red/error styling; "Syncing…" chip with settled count during replay; a queued op the server later rejects is shown as a retraction in the sync summary, never silently corrected.
- Web surfaces: Inbound (POs with open quantities, GRNs, blind-GRN flags, QC holds); Settings houses floor-device enrollment/revocation; Conflicts & Reviews is the single human-review queue (quarantined replay conflicts, over-receipt approvals) — over-receipt approvals land there mid-receive. Approval cards carry threshold context inline and write to the audit trail.
- Accessibility floor: every task state announced via VoiceOver/TalkBack ("Bin accepted", "Wrong item — expected SKU …"); dynamic type honored (scan banner legible at largest setting); Reduce Motion makes banner swaps instant; scan-result is the largest text on any task screen.
- Microcopy: numbers and verbs, no exclamation marks — "Queued 14 — will sync when Wi-Fi returns", not "Network error. Retrying…". Mockup reference: `mockups/key-mobile-receive.html` (spine/UX docs win on conflict).

## Cross-Story Dependencies

- Depends on Epic 1: tenants, warehouses, zones/bins, SKUs (with barcode values at catalog entry), users/roles, and the monorepo scaffold that includes the Expo mobile shell.
- Depends on Epic 2: all receipts, holds, releases, putaways, and merges write ledger events through the inventory module; QC-held ATP is the hook Epic 2 left in the ATP formula — this epic populates it.
- Within the epic: 3.2 (mobile substrate) is the substrate 3.3, 3.5 consume; 3.1 (POs) is the basis for 3.3's receiving; 3.3's GRNs feed 3.5's putaway suggestions; 3.6's block state feeds 3.5's suggestion filtering and picking.
- Later epics extend, never rework: Epics 4/5 add new task types (pick, count, transfer) to the inbox and reuse scanning, outbox, and replay; over-receipt approvals join the Conflicts & Reviews queue that Epic 5 extends with variances.