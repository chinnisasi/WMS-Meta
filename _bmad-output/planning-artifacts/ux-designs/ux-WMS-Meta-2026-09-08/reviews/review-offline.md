---
name: UX Review — Offline & Offline-Recovery Experience
status: draft
created: '2026-09-08'
reviewed:
  - ../DESIGN.md
  - ../EXPERIENCE.md
  - ../../../architecture/architecture-WMS-Meta-2026-09-08/ARCHITECTURE-SPINE.md (AD-2, AD-4, AD-12, AD-14, AD-17 binding)
method: end-to-end offline stress of badge-in, claim, queue, replay, conflicts, revocation, inbox staleness
---

# UX Review — Offline & Offline-Recovery Experience

## Verdict

**Needs work before build.** The *offline mechanics* are well specified and the spines mirror each other correctly on the happy path: on-device decisions, FIFO outbox, queue-depth-not-error, re-authorization at replay, four-case conflict taxonomy. What is missing is the **offline-recovery narrative** — the seam where the device reconnects and server truth disagrees with what the operator saw and did offline. Three states are entirely unrepresented (offline badge-in, the operator-facing face of quarantines, mid-shift device revocation), and the scan banner's promise ("accepted") is architecturally breakable at replay with no representation of the break. Every finding below names the concrete spine addition that closes it.

Severity key: **critical** — breaks the operator trust model or loses work; **high** — unrepresented state that needs a spine decision before any build; **medium** — incoherent or under-specified transition; **low** — polish.

---

## Findings

### F-1 · Scan banner makes a promise the server can retract — no representation of retraction [CRITICAL]

**Stress:** Ramesh is offline in aisle C. He scans a batch against a pick task. On-device FEFO logic selects the batch it believes is correct — from the local snapshot of bin state, last synced maybe 20 minutes ago. Banner: **green, "Bin accepted / FEFO batch 4471"**, the largest text on the screen (DESIGN.md scan-result). Meanwhile another operator's replay landed a newer receipt on the server before his replays. At replay his pick hits `state_epoch` mismatch — AD-14 case 3 or case 4. His device told him *accepted*; the server disagrees.

**Gap:** AD-4 says scan decisions run on-device and AD-10 says on-device validation "mirrors — never overrides — server rules," but the EXPERIENCE scan-banner pattern (Component Patterns, State Patterns) has exactly three states — green accept, red reject, amber attention — and all of them are presented as *final*. The taxonomy distinguishes "self-verifiable" rejections (wrong item, wrong bin — deterministic from task data, safe to settle green offline) from **state-dependent decisions** (FEFO batch selection, quantity feasibility, task claim) whose truth can move between scan and replay. Nothing on the device distinguishes the two, so the operator's mental model — green means it counted — breaks exactly in the dead-zone scenario the product is built for.

**Proposed spine addition (EXPERIENCE.md → Scan banner pattern):**

> Offline scan banners carry a truth class. *Self-verifiable* decisions (expected-SKU mismatch, wrong bin, debounce, task-data checks) settle fully on-device — green is final. *State-dependent* decisions (FEFO batch choice, quantity feasibility, claim, anything reading bin state) settle green **with a queued tag** and a one-line voice-table entry ("Queued — server confirms this pick at sync."). Green-without-tag may only appear when the device is online. Every retraction at replay maps to exactly one named operator transition (see F-4, F-6) — a scan banner may never silently change meaning.

### F-2 — Badge-in is a server write with no offline path — the shift cannot start in a dead zone [CRITICAL]

**Stress:** Ramesh's tablet rebooted overnight (or his session expired, or the app was killed by the OS). He badges in at the start of shift, in the same dead zone he will pick in. Badge-in "scan operator badge; assigns session to operator" — a server write. Offline, it fails. The only screen the entire offline design does not survive is the first one: **the operator is stopped at the door by the product whose promise is "no wait-for-network moments."**

**Gap:** AD-4 covers scan persistence and replay authorization; it says nothing about session acquisition. EXPERIENCE.md's mobile IA roots everything in badge-in with no offline variant. Unrepresented: first-run-of-day offline badge-in; session-expiry mid-offline-shift; the interaction between a locally-acquired session and AD-4's "re-authorized against current session state at the server" (queued ops must attribute to *something*).

**Proposed spine addition (EXPERIENCE.md → Badge-in surface; mirrors an AD-4 sub-rule):**

> Badge-in is offline-tolerant against the device's last-known operator identity: if the operator and device were valid at last sync, a cached session opens immediately, marked "session revalidates when Wi-Fi returns"; a first-ever badge-in on the device requires network. A cached session that fails re-validation at replay routes that session's queued ops to the F-4 outcome, never to silent drop. Queued ops always carry the session/operator identity they were scanned under (see F-7).

### F-3 — Offline task claim races: the loser has work in progress and no defined state [CRITICAL]

**Stress:** Two operators, one bin, one picklist. Ramesh is offline; his inbox shows a claimable task card. He claims it (optimistic, per Task card pattern) and starts picking — 8 of 12 lines scanned into his tote. Meera, online, claims the same task from her device; her claim wins server-side. Ramesh reconnects; his claim (and possibly his picks) replay and lose the race.

**Gap:** FR-29's "disappears for others within one refresh cycle" is an *online* reconciliation rule; it says nothing about the offline direction, and AD-14's taxonomy resolves the *event*, not the *operator experience*. Four unrepresented states: (a) can a claim be made offline at all — is it an AD-14 "always online" operation or a settleable outbox op? (spine is silent); (b) after losing the claim race, what does Ramesh's task card become — still "claimed by you," tombstoned, reopened?; (c) what does he physically do with the 8 units already picked (return to bin? keep? which one?); (d) nothing stops him scanning the remaining 4 lines against a task the server has given away.

**Proposed spine addition (EXPERIENCE.md → Task card pattern + State Patterns):**

> Task claim is a state-dependent outbox op (not settleable silently). If a claim loses its race at replay, the task card resolves on-device to **"claimed by another operator"** — a tombstone state with the other operator's name — the operator's in-progress lines are itemized in the sync results (F-4) with physical instruction ("return 8 units to bin A-03-12"), and the task card's flow is closed on-device so no further scans can attach to it. New tasks claimed by others while offline resolve to the same tombstone on the device's next sync; the offline inbox always shows a last-synced age marker (see F-8).

### F-4 — Quarantine has no operator-facing surface; "next sync summary" is undefined [HIGH]

**Stress:** AD-14 case 4 fires on three of Ramesh's replayed picks (unresolvable). The design says rejections "quarantine to Conflicts & Reviews and appear in the operator's next sync summary, never blocking further work." But **Conflicts & Reviews is a web sidebar area** — Ramesh is a mobile-only operator with no account on Priya's dashboard. And "next sync summary" appears nowhere else in either spine: no component, no surface, no timing, no content spec.

**Gap:** The operator learns his work did not land through a surface he does not have, described by a component that does not exist. Worse: a quarantined pick means *physical stock in a tote that the system does not know about* — the single most operationally dangerous offline outcome — and the operator's only prescribed moment to learn of it is "next sync summary," undefined. The mobile push allowlist (task assignment + approval-needed + at-risk cutoff) does not include quarantine or re-plan notices, so nothing can reach his device even in principle.

**Proposed spine addition (EXPERIENCE.md → new "Sync results" mobile surface + Notification panel rule):**

> A **Sync results** view opens from the mobile inbox header (reachable offline and online): per replay batch — settled count, re-authorized-rejected count, quarantined items each with reason, the original task ref, and the required physical action ("6 units picked to tote 2 did not settle — return to bin A-03-12" / "your count on B-07 needs a recount task"). Quarantine of one of your ops and re-plan of one of your tasks are added to the allowed mobile push set. The web Conflicts & Reviews queue is the *manager's* resolution surface; the mobile Sync results view is the *operator's* — the two link on task ref.

### F-5 — Device revocation mid-shift: the holder's experience is entirely unwritten [HIGH]

**Stress:** AD-4: "Devices are enrolled and revocable; a wiped/lost device's cache is useless." Revocation happens from web Settings. Two cases, neither represented: **(a) revoked while online** — Ramesh's next scan is re-authorized and rejected; what does the screen say, who does he hand the device to, does his completed queue survive? **(b) revoked while offline** — on-device decisions never check revocation, so the device keeps accepting scans and queues them; at replay every op is rejected ("a deactivated operator's queued actions do not apply"), producing a **mass quarantine** — potentially 100+ ops of real physical work evaporating with no on-device warning. Between revocation and wipe-flag execution, the device's behavior is unspecified; nothing in the spines defines a local deprovisioning path.

**Proposed spine addition (EXPERIENCE.md → State Patterns, new "Device revoked" row; AD-4 sub-rule):**

> Revocation has two operator paths. *Online/next-contact*: the device shows a stop-work screen ("This device was deactivated. Hand it to your supervisor.") and blocks new scans; queued ops attributable to a still-valid session replay first, then the wipe flag executes. *Offline*: queued ops carry a pending-age cap (default: one shift); a device whose queued ops exceed the cap or whose session re-validation fails at replay stops accepting new scans and surfaces the Sync results view with the mass-quarantine explanation, not silence. Revocation never deletes an outbox before its contents reach a terminal settle/quarantine state.

### F-6 — AD-14 case 3 re-plans arrive as mid-shift card injects with no transition spec for the original task [HIGH]

**Stress:** Ramesh is mid-pick on task T-2 when the epoch conflict on his earlier task T-1 resolves to case 3 at replay. A new re-plan card "linked to the original task ref" appears in his inbox mid-shift. The voice table supplies the *reason line* ("Bin A-03-12 is blocked — pick from B-01-04 instead") — good — but the spines never define: (a) what state the **original task card** enters (completed-with-shortfall? replaced? reopened?), (b) what happens to the **lines he already scanned** against the now-stale plan (are they settled under case 2, re-scoped onto the new card, or voided?), (c) whether he can be **mid-scan on the affected bin** when the re-plan card arrives — he was offline, so conflict detection is deferred to replay; between reconnect and card arrival nothing prevents him from re-scanning the exact stale plan; (d) whether a re-plan card can itself arrive while he is still offline (it cannot — it is a server artifact — but the design never says the inbox must show a "re-plan pending on T-1" marker derived from replay outcomes).

**Proposed spine addition (EXPERIENCE.md → Task card pattern):**

> A case-3 re-plan: the original task card resolves to **"re-planned"** with its settled lines retained and a link to the new card; the new card carries the reason line and the remaining quantity, pre-targeted at the alternate bin. While a task's conflict is unresolved, its card shows an amber "server is re-checking this task" marker so the operator does not re-scan into a moving bin. The re-plan is delivered with the replay batch (same sync), never on a later refresh.

### F-7 — Queued ops authorize against which session? Shared devices have no outbox attribution rule [HIGH]

**Stress:** Warehouse tablets are shared between shifts. Ramesh queues 30 picks offline, badges out (or is deactivated at shift end), Meera badges into the same tablet, queues 25 more ops. AD-4: replay "re-authorizes against current session/role/device state" — *which* session? If it is the device's current session, Meera's badge-in retroactively authorizes Ramesh's ops (an authorization laundering path that contradicts AD-10); if it is the scanning session, the spines never say ops carry session identity, and Ramesh's queued ops face deactivation-era rejection with no F-4-style explanation.

**Proposed spine addition (AD-4 sub-rule + EXPERIENCE.md badge-out):**

> Every outbox op is stamped with the scanning operator's session id and ULID-attributed actor; replay authorizes each op against **its own session's current server-side state**, never the device's current badge-in. Badge-out on a device with a non-empty outbox shows the queue count and states plainly: "30 actions still settling — they will sync under your session even after you badge out." Shift-change badge-in is not blocked by a foreign queue (that would be a wait-for-network moment); it is warned.

### F-8 — The mobile inbox has no staleness pattern; web's stale-data rule does not port [MEDIUM]

**Stress:** The State Patterns table gives web lists an inline refresh banner and "lists never auto-refresh." The mobile inbox — the operator's entire world for a shift — has no equivalent. While offline: tasks assigned to others still show claimable; tasks others completed still show open; new assignments are invisible. Ramesh works from a list that is silently 40 minutes old, and nothing tells him.

**Proposed spine addition (EXPERIENCE.md → State Patterns):**

> Mobile inbox carries a persistent last-synced age marker (muted; turns amber at a configurable threshold, default 15 min). Offline reconciliation at next sync applies tombstones (F-3) rather than silently dropping stale cards. The inbox never pretends freshness it does not have — the queue chip governs outbound truth, the sync-age marker governs inbound truth.

### F-9 — Queue chip semantics across a long shift: depth without age, and no empty-offline-inbox state [MEDIUM]

**Stress:** 30+ minutes offline, 100+ queued ops. The chip says "Queued 104 — will sync when Wi-Fi returns." Three incoherences: (a) **depth without risk** — a cutoff-bound pick queued at position 90 has materially different urgency than position 3; the chip's single number cannot express this, and there is no per-oldest-op-age or task-level queued indicator, so a supervisor cannot triage from the floor; (b) **replay/queue chip duality** — when connectivity returns mid-shift, does the queue chip become the "Syncing…" chip, do both show (queued draining while new ops queue during a flapping connection), and does the settled count tick on the same chip? The transition between the two chips' semantics is undefined; (c) **the offline-empty inbox** — offline, no new tasks can arrive (fresh grants are always-online per AD-14), so an operator who finishes their list in a dead zone stares at an empty inbox with a queue chip and nothing else; the state has no defined content ("All picked — 24 actions queued. Ask for new work when Wi-Fi returns.").

**Proposed spine addition (EXPERIENCE.md → Queue state pattern):**

> The queue chip shows depth plus oldest-op age ("Queued 104 · oldest 32 min"); amber escalates visually (never to red/error) past a configurable age. On reconnect the chip morphs to "Syncing… 37 of 104 settled," returning to depth semantics if connectivity drops mid-replay; the two states are one component, never two chips. Offline-empty inbox is a first-class empty state naming the queue count and the path to new work.

### F-10 — Replay ordering across interleaved offline work is underdetermined [LOW]

**Stress:** AD-4 says FIFO outbox and "replays in task order"; AD-14's epoch check assumes task-coherent ordering. One operator working pick T-1, switching to count C-1 mid-dead-zone (inbox suggests it), then back to T-1 produces an outbox whose chronological order interleaves two tasks. Chronological replay is correct for epoch-checking, but "in task order" is ambiguous and a naive task-grouped replay could fail epoch checks that chronological replay would pass. One sentence in AD-4 or the UX spine resolves it: replay is strictly chronological (FIFO); task order is presentation, not settlement order.

### F-11 — Badge-out and shift end are absent from the spine [LOW]

Badge-in is the root; there is no badge-out, no shift-close, no "settle your queue before you leave" moment (F-7 covers the warning). A shift-bounded product should name the shift-bounded states: badge-out confirmation with queue count, and what an un-badged device shows on next open (badge-in screen with the previous session's queue visible-but-frozen).

---

## AD-14 taxonomy × operator experience map (the coherence check)

| Case | Server behavior (AD-14) | What the operator experiences today | Verdict |
|---|---|---|---|
| 1 — quantity unchanged | Apply | Nothing (silent settle on sync chip) | Coherent |
| 2 — reservation valid | Settle | Nothing (silent settle) | Coherent |
| 3 — bin moved on | Short-pick / re-plan (FR-15) | A new card appears, reason line exists, but original-card state, in-progress lines, and mid-conflict marker undefined | **F-6, HIGH** |
| 4 — unresolvable | Quarantine, never blocking | "Next sync summary" — undefined; Conflicts & Reviews is web-only; physical stock disposition unstated | **F-4, HIGH** (F-1 critical underneath: the green banner already promised the wrong thing) |

## Severity summary

| Severity | Findings |
|---|---|
| Critical | F-1 (scan-banner retraction), F-2 (offline badge-in), F-3 (claim race) |
| High | F-4 (quarantine surface), F-5 (revocation), F-6 (case-3 transitions), F-7 (session attribution) |
| Medium | F-8 (inbox staleness), F-9 (long-shift chip) |
| Low | F-10 (replay ordering), F-11 (badge-out) |

## Consolidated spine additions (ready to fold into EXPERIENCE.md / AD-4)

1. **Scan-banner truth classes** — self-verifiable vs state-dependent on-device decisions; retraction must map to a named operator transition (F-1).
2. **Cached-session badge-in** — offline badge-in against last-known-valid identity, revalidated at replay (F-2).
3. **Claim tombstone + partial-work disposition** — lost claim races resolve to a named card state with physical instruction (F-3).
4. **Mobile Sync results surface** — per-replay settled/rejected/quarantined with physical actions; quarantine + re-plan added to the mobile push allowlist (F-4).
5. **Revocation two-path spec** — stop-work screen on contact; pending-age cap and mass-quarantine explanation offline; outbox never deleted pre-settlement (F-5).
6. **Case-3 card transitions** — original card → "re-planned," settled lines retained, amber "server is re-checking" marker while unresolved (F-6).
7. **Outbox session attribution** — ops carry scanning-session identity; replay authorizes per-op against its own session; badge-out warns on non-empty queue (F-7).
8. **Inbox sync-age marker + tombstone reconciliation** (F-8).
9. **Queue chip: depth + oldest age; single morphing component across queue↔sync states; offline-empty inbox state** (F-9).
10. **Replay order is chronological; task order is presentation** (F-10).