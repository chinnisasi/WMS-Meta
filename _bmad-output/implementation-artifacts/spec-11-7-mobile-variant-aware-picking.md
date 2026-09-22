---
title: 'Mobile variant-aware picking'
type: 'feature'
created: '2026-09-22'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: 'wms-be 1927fc9 / wms-mobile a4f0144'
context:
  - '_bmad-output/implementation-artifacts/epic-11-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/catalog.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
  - 'docs/repos/wms-mobile/README.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** After 11-3/11-4, a size×colour SKU and a kit component are indistinguishable on the device: the pick task screen shows only the SKU code, the post-scan announcement names the SKU name alone, the wrong-scan rejection names two bare codes, and nothing says a line is a kit component (FR-37/FR-38; UX-DR28 — picking the wrong size is the dominant apparel error).

**Approach:** Additive snapshot fields (`axes`/`variantValues` on the catalog-snapshot SKU arm; `kitParentSkuCode` on the pick-task arm), pure mobile helpers that compose the display strings, and three rendering surfaces on the pick screen — the variant leads the post-scan announcement, is the largest distinguishing text on the task screen, and names both variants in the wrong-scan rejection. Op payloads, the queue path and the replay engine are untouched.

**Decisions (2026-09-22):**
- Kit context rides the task arm as the parent kit's SKU code only — not the BOM, not `parentLineId` — and renders as a `from kit {code}` line in the task header, which persists across every step.
- The variant label format matches the web's `size: M · colour: Red` (axes order); a value missing under present axes renders an honest `axis: —` (web-identical); the alphabetically-sorted-keys fallback is defensive only (both fields ship in this story, so a seal carrying values without axes is unreachable today).
- When a task's SKU carries a variant, the task header renders the label at `typeScale.scanResult` (wrapping, ellipsized) and demotes the SKU code to the progress line, exactly per UX-DR28; the announcement keeps the full, untruncated label.
- The wrong-scan rejection composes in `verifyTaskSku` (the model is the prose home): each side reads `size: M · colour: Red (SKU-123)` when it carries a variant, bare code otherwise — byte-identical to today's prose when neither side does.
- The walk picker and inbox cards keep the SKU code as list identity and change not at all; the other banner arms (take-task, bin-step, serials, short-pick) keep code-only identity — the header carries the variant persistently, so nothing is lost.

## Boundaries & Constraints

**Always:**
- Snapshot growth is additive (mobile guide §4): a device sealed by an older build must show no variant and no kit context — never crash, never block a scan. Absent ≠ null: absent means "older server", null means "not a variant / not a kit component". `parseCatalogSnapshot` is untouched — absence flows through the spread to the helpers as `undefined`.
- Operator-facing prose is composed in pure, tested modules (`src/picking/variant.ts`, `src/picking/draft.ts`) and rendered verbatim — the **full** announcement and rejection strings, not just the label, are pinned by tests (`app/` has no test seam, mobile guide §8).
- `bun run openapi:export` in wms-be regenerates the device contract; the FE regenerated client must be re-committed in the same story (the drift guard), even though no web surface consumes it.

**Never:**
- No change to the queued op payloads (`confirmPayload`), `enqueueOp`, the outbox engine, replay classification, or the four-state banner states.
- No web surface change (the regenerated client is comment/shape-additive only).
- No kit BOM, no parent line id, no pack-task or putaway/receive variant work — the pick path only.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Variant SKU verified | Scan matches a SKU whose `variantValues` = `{size:'M', colour:'Red'}`, product axes `[size, colour]` | Banner detail reads `size: M · colour: Red — {sku name} verified — confirm N unit(s)` (serial variant: `— scan N serial(s)`); task header shows the label at `scanResult` scale (wraps, ellipsized), SKU code demoted below | N/A |
| Unattached SKU verified | `variantValues` null (or absent on an older seal) | Banner and header render byte-identically to today — banner `{name} verified — confirm N unit(s)`; header code at `scanResult` scale (the header never shows the name today) | N/A |
| Value missing under present axes | `variantValues` = `{size:'M'}`, axes `[size, colour]` | Label composes `size: M · colour: —` (web-identical); never `undefined` | N/A |
| Values without axes (defensive) | `variantValues` present, `axes` absent | Unreachable from this story's server (both fields ship together); label composes from alphabetically sorted keys — deterministic | N/A |
| Wrong-scan rejection | Task picks a variant SKU; operator scans a sibling variant | Banner detail reads `Scanned size: M · colour: Red (SKU-B) — this line picks size: S · colour: Red (SKU-A) — the scan is not recorded`; with neither side carrying a variant, today's exact prose `Scanned {code} — this line picks {code} — the scan is not recorded` | Scan rejected, not queued (existing structural budget) |
| Kit component task | Pick task's order line has `parent_line_id` → parent kit SKU `KIT-01` | Task header shows the kit context line `from kit KIT-01` (persists across all steps); ordinary lines show nothing | N/A |
| Legacy snapshot seal | Cache sealed before this story | `variantLabel` returns null, no kit context renders; `parseCatalogSnapshot` untouched; legacy-seal test asserts by equality with the new keys **omitted** (`toEqual` ignores undefined-valued keys) | N/A |

</frozen-after-approval>

## Code Map

- `wms-be/src/modules/catalog/catalog.facade.ts` (`SkuSummary` :103-137, `getSkuSummariesInTx` :213-233) -- add `variantValues` (already a `skus` column) + `axes` (left join `products`; null when unattached) to the select and the mapped summary
- `wms-be/src/modules/inbound/receiving.facade.ts` (inline `CatalogSnapshot` SKU mirror :67-79) -- **third** mirror of the 10.2/10.3 precedent — keep in lockstep or the story ships with a silently stale mirror
- `wms-be/src/modules/inbound/receiving.dto.ts` (`CatalogSnapshotSkuDto` :449-485) -- mirror the two fields exactly; `openapi:export` then regenerates `openapi/openapi.json` (the export exits 0 silently — prove the contract moved with `git diff --exit-code openapi/`)
- `wms-be/src/modules/outbound/pick.command.ts` (internal `PickTask` interface :222-257, `getPickTasksInTx` :1601-1693) **and** `wms-be/src/modules/outbound/outbound.dto.ts` (`PickTaskDto` :866-922) -- add `kitParentSkuCode: string | null` on **both** type sites: `picklist_lines.orderLineId` → left join `order_lines` → left join parent line on `parent_line_id` → left join `skus` for the parent's code (null on ordinary lines)
- `wms-be/test/receiving.spec.ts` (:906-956 the snapshot pin) + `wms-be/test/picking.spec.ts` (:2430 the pickTasks pin) -- extend both with the new fields and both null arms; fixtures are built **inline per spec file** (`test/support/` has no product helper — `test/products.spec.ts:192-196` is the pattern reference, not an importable fixture)
- `wms-mobile/src/api.ts` (`CatalogSku` :554-575, `CatalogPickTask` :629-661) -- add `variantValues?: Record<string, string> | null`, `axes?: string[] | null` on the SKU; `kitParentSkuCode?: string | null` on the task (optional per the `binStateEpoch` precedent: absence is a real state on an older seal)
- `wms-mobile/src/picking/variant.ts` (NEW) -- pure, dependency-free: `variantLabel(sku | undefined): string | null` (axes order, `—` for a missing value, sorted-keys defensive fallback, undefined/null → null), `describeSku(sku | null | undefined): string` (variant label + code when labelled, bare code otherwise), `verifiedAnnouncement(sku, qty, serialTracked): string` (the **full** banner detail for both arms), `kitContext(task): string | null` (`from kit {code}`); no React, no store, no awaits
- `wms-mobile/src/picking/draft.ts` (`verifyTaskSku` :255-267, rejection prose :264) -- gains an optional `taskSku?: CatalogSku | null` param (the caller already resolves it for the header); the wrong-SKU rejection composes `describeSku` on both sides; the draft shape does not change
- `wms-mobile/app/pick.tsx` -- :199-226: the verified banner renders `verifiedAnnouncement(...)` verbatim (both arms), the rejection path is unchanged; :378-380: `taskSku` is now also passed into `verifyTaskSku`; :453-464: task header renders the label at `typeScale.scanResult` with `numberOfLines` + ellipsize, the code demoted to `progressCopy`, and the `from kit` line — nothing else in the step machine moves
- `wms-mobile/src/state/catalog-snapshot.ts` -- untouched; `device-store.test.ts` gains the legacy-seal arm asserting an old seal's SKU passes through with the new keys omitted (equality, not `toMatchObject`; omit, never `undefined`, in the expected object)
- Not to change: `src/offline/**`, `src/state/op-dispatch.ts`, `src/state/replay-classification.ts`, `confirmPayload`/`enqueueOp`, `app/inbox.tsx`, the WalkPicker, any web component, and every other banner arm (take-task :163, bin-step :180-182, serials :235-239/:448, short-pick :258-262/:294-298)

## Tasks & Acceptance

**Execution:**
- [ ] `wms-be` catalog.facade.ts + receiving.facade.ts inline mirror + receiving.dto.ts -- variant fields across all three SKU-arm mirrors -- the data
- [ ] `wms-be` pick.command.ts (`PickTask` + query) + outbound.dto.ts (`PickTaskDto`) -- `kitParentSkuCode` on both task type sites -- the kit context
- [ ] `wms-be` spec tests -- snapshot sku-arm fields + kit-parent task field, both null arms, inline fixtures -- the proof
- [ ] `wms-fe` `bun run api:generate` -- regenerated client, additive only -- the drift guard
- [ ] `wms-mobile/src/api.ts` + `src/picking/variant.ts` + tests -- interface + pure helpers (label, describe, full announcement, kit context) -- the offline brain
- [ ] `wms-mobile/src/picking/draft.ts` + draft.test.ts -- wrong-scan rejection carries both variants -- the UX-DR28 rejection arm
- [ ] `wms-mobile/app/pick.tsx` -- announcement + task header (label, demoted code, kit line) -- the UX-DR28 surface
- [ ] meta `docs/` -- mobile design docs, `docs/repos/wms-mobile/README.md` contract, PENDING closure, `docs/design/modules/outbound.md` invariant amendment note -- keep the docs true

**Acceptance Criteria:**
- Given a variant SKU (axes size/colour) in a pick task, when the item scan verifies, then the banner announcement leads with `size: M · colour: Red` and the task header shows that label at the largest text scale (wrapping, ellipsized) with the code below.
- Given an unattached SKU, when the same flow runs, then the banner and header render byte-identically to today — proven by the helper tests asserting today's exact strings for both the verified and rejected arms.
- Given a scan of a sibling variant, when the item scan is verified against the task, then the rejection names both variants (`Scanned {label} ({code}) — this line picks {label} ({code})`), and with neither side variant-carrying it is today's exact prose.
- Given a kit-exploded pick task, when the walk renders, then the task header shows `from kit {KIT-CODE}`; an ordinary task shows no kit line.
- Given a snapshot sealed by the pre-story server, when any pick task renders, then nothing variant- or kit-related renders and no legacy-seal test regresses.
- Given the whole suite, then wms-be `bun run test/lint/typecheck`, wms-mobile `bun run test/typecheck` (wms-mobile has no lint script), and wms-fe `bun run test` + capability-mirror after the client regen all pass.

## Implementation Notes

## Spec Change Log

- 2026-09-22 (design review): wrong-scan rejection arm added to scope (human decision); Code Map corrected (`PickTaskDto` → outbound.dto.ts, internal `PickTask` site, receiving.facade.ts third mirror); missing-value arm defined web-identical; announcement/rejection prose moved fully into pure helpers; AC and verification commands made provable.
- 2026-09-22 (code review): review findings patched (see the Review Triage Log) — legacy-seal key-absence assertions, `variantLabel` empty-values arm, `verifyTaskSku` taskSku guard + mirror arms, `kitContext` empty-string guard, kit-parent-line-absent pin, expose-side README entry, four doc corrections.

## Review Triage Log

- 2026-09-22 — three layers over the design (blind-hunter, edge-case-hunter, verification-gap), 32 raw findings → 8 root causes:
  1. `PickTaskDto` anchored to wrong file; task change touches three type sites; SKU arm has a fourth mirror (`receiving.facade.ts:67-79`) — **high** — Code Map rewritten.
  2. Wrong-scan rejection carried no variant context (the exact UX-DR28 error) and the exclusion was implicit — **high** — escalated to human; **included** in scope.
  3. Optional typing vs parse-normalization contradiction — **medium** — resolved: fields stay optional (`binStateEpoch` precedent), `parseCatalogSnapshot` untouched, legacy-seal test asserts keys omitted.
  4. "Byte-identical" unprovable (banner composition lived in untested `app/`) — **high** — full announcement composed in `variant.ts`, both arms pinned.
  5. Values-without-axes arm unreachable and web-divergent; reachable missing-value arm unspecified — **medium** — `axis: —` defined web-identical; sorted-keys kept as marked-defensive.
  6. No worst-case label bound at 28px — **medium** — header wraps/ellipsizes; announcement keeps full label.
  7. Verification commands unprovable as written — **medium** — wms-mobile lint dropped (no script), `git diff --exit-code openapi/` added, FE drift noted CI-enforced.
  8. Low findings folded in: anchor drift, `pick.tsx:378-380` mischaracterization, banner/header "name first" conflation, non-shareable test fixtures, kit-line render position, snapshot payload growth accepted, `outbound.md:264` invariant amended display-only, unicode `·` collision accepted (web parity), prompt arms stay code-only.
  - Verified clean by the reviewers and recorded: `parent_line_id` survives cancel (order lines never deleted); the join's parent is always a kit SKU (kit parents hold no reservation, waves plan only held lines); axes/values drift impossible server-side (all writes serialize on the product row `FOR UPDATE`); kit context repeats correctly per slice; no positional consumers of `CatalogSku`/`CatalogPickTask`; announcement order satisfies UX-DR28 literally via the `word. detail` banner composition.

- 2026-09-22 — code review (three layers over the implemented diff; all suites independently re-run green: wms-be 699 + lint/typecheck/openapi-drift, wms-fe 341 + zero-diff regen + capability mirror, wms-mobile 271 + typecheck). No high-severity findings. Patched:
  1. Legacy-seal test hardened — key ABSENCE asserted directly (`toEqual` alone waves an `undefined`-valued insertion through, the exact regression the arm exists to catch).
  2. `variantLabel` empty-values-with-axes now renders all-dash pairs (web-identical) — the shape is DB-legal (`skus_variant_values_pairing` requires only a jsonb object), not merely command-refused.
  3. `verifyTaskSku` guards the caller's `taskSku` (id must match the task) — a stale/mis-resolved lookup never speaks for the line; mirror arm (bare scan, variant-bearing line) and the mismatch arm pinned.
  4. `kitContext` refuses an empty-string code (drift, not a kit); `axes: []` fallback arm pinned.
  5. wms-be kit test now pins that the kit parent's own unplanned line never appears as a task.
  6. Trailing newlines on the new mobile files.
  - Doc corrections patched: `docs/repos/wms-be/README.md` got its 11-7 expose-side entry and the snapshot sku-arm shape made current (stale since 10.2 — the spec's meta task had omitted the expose-side READMEs); API-SURFACE `10.6` tag moved off `uomPrecision` (10.2) onto `catchWeightTracked`; mobile guide growth list corrected to eight growths with 10.2 named as the first per-row growth; `catalog.md` facade anchors made current (`:210`/`:227`).
  - Deferred, recorded as accepted drift-only behavior (display-only, unreachable via the API today): self-referencing `parent_line_id` would render the line's own code as kit context; an orphaned product row turns the sorted-keys fallback into the live shape; a deleted parent kit SKU demotes a component to an ordinary line; `String(value)` trusts jsonb more than the DB does (web-parity composition, the stated acceptance).

## Design Notes

- **Why the SKU arm and not the task arm for variant data:** the pick screen resolves the scanned SKU out of `snapshot.skus` via `resolveBarcode` (`app/pick.tsx:199`, re-exported from `src/receiving/draft.ts`), and the task's SKU via the `taskSku` lookup at :378-380 — the variant rides lookups that already exist; the pick-task query stays untouched for variant data. Kit context is the opposite: it belongs to the *line*, so it rides the task.
- **The helpers are the test seam — for the whole prose, not just the label.** Nothing under `app/` has a test (mobile guide §8): the full verified announcement lives in `variant.ts`, the rejection prose in `draft.ts`, both pinned verbatim with the web's separator (` · `) so all surfaces tell one story.
- **Announcement asymmetry, taken explicitly:** the variant leads the announcement (UX-DR28: first element after the scan result); kit context is header-only — persistent across steps, absent from the announcement; the other banner arms keep code-only identity. The header's persistence makes each of these losses zero.
- **Snapshot payload growth, accepted:** the `skus` arm is tenant-wide and unbounded (only `pickTasks` truncates at 500); `axes` is duplicated per sibling variant (~hundreds of bytes per variant SKU). Accepted for this story; axes deduplication goes to PENDING if a tenant ever measures it.
- **`outbound.md` invariant amended, display-only:** "no kit-aware machinery exists below the outbound module" gains an explicit exception — the pick-task read now surfaces `kitParentSkuCode` for display; no pick/pack/dispatch logic reads kit-ness. The module doc update says so.
- **Unicode joiners:** axis values are only blank/length-checked, so a value may contain `·` or ` — ` — accepted, web-parity (the web grammar has the identical collision); no new guard in this story.
- **`verifyTaskSku` seam:** the optional `taskSku` param is the only model-seam change; the caller already computes it for the header, the draft shape is untouched, and the `undefined`-tolerant helpers degrade to today's prose on a stale cache.

## Verification

**Commands:**
- `wms-be`: `bun run test && bun run lint && bun run typecheck && bun run openapi:export && git diff --exit-code openapi/` -- expected: green; snapshot specs pin the new fields and both null arms (the CI `openapi` job is the same check)
- `wms-fe`: `bun run api:generate && bun run test && bun run check:capability-mirror` -- expected: green, additive generated types only (the drift guard itself is wms-fe CI's `generated-client` job — the committed regen is what passes it)
- `wms-mobile`: `bun run test && bun run typecheck` -- expected: green incl. the new pure-helper suite, the draft rejection pins, and the legacy-seal arm (wms-mobile has no lint script)

**Manual checks (if no CLI):**
- Walkthrough: enroll → badge-in → pick a variant task: variant announced first after the scan result, largest text on the task screen; scan a sibling variant: both variants named in the rejection; pick a kit component: `from kit` line present in the header across steps; airplane-mode sweep unchanged.