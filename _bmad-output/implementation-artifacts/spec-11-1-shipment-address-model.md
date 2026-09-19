---
title: 'Shipment address model'
type: 'feature'
created: '2026-09-19'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: 'wms-be 80c7515 / wms-fe 9719c12'
context:
  - '_bmad-output/implementation-artifacts/epic-11-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** There is no address model anywhere — orders carry no destination and warehouses carry only `code` + `name` — so nothing can be rated, labelled or manifested (PENDING.md:109; the hard blocker behind story 4-6d).

**Approach:** Structured, flat address columns on `orders` (destination) and `warehouses` (origin), validated command-side, echoed in the order and warehouse APIs, and enterable on the two web create forms. Mobile needs no change (structural casts ignore new fields).

## Boundaries & Constraints

**Always:**
- Addresses are structured, never free text. One field set both sides: `contactName`, `phone`, `line1`, `line2` (optional), `city`, `state`, `pincode` — pincode is **text** (`/^\d{6}$/`, leading zeros preserved), never an integer.
- Destination/origin validation lives in the **command**, not only the DTO — the Epic 7 adapter path bypasses DTO validation.
- If any destination/origin field is present, all required ones must be — an address is atomic, never partial.

**Never:**
- No country field (India-only system: GST, paise, Indian carriers) — extensibility is noted, not built.
- **DECISION (human, 2026-09-19): addresses are required at create** — `destination` required on every createOrder (manual and ingested), `origin` required on createWarehouse. Pre-launch, zero backfill; pre-11.1 rows read back `null` and are simply unrated. 4-6d is unblocked unconditionally.
- No warehouse PATCH/update endpoint and no FE edit surface for pre-existing warehouses — the update path is 4-6d's to add if rating needs it.
- No mobile changes; no new error codes (shape errors are 400 `validation-failed`).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Manual order with destination | createOrder body carries full `destination` object | 201; `destination` echoed in snapshot and GET/list responses | N/A |
| Ingested order with destination | `source: "ingested"` + destination + channel arms | 201; destination participates in both payload hashes | N/A |
| Missing destination | createOrder body without `destination` | 400 `validation-failed` before any write | preflight, 400 |
| Partial destination | e.g. `line1` present, `pincode` absent | 400 `validation-failed` naming the missing field | preflight, 400 |
| Bad pincode | `pincode: "11001"` or `"1100011"` or non-digits | 400 `validation-failed` names pincode | preflight, 400 |
| Pre-11.1 order read back | order row predating the migration | `destination: null` in the response | N/A |
| Warehouse with origin | createWarehouse carries `origin` | 201; `origin` echoed in warehouse list | N/A |
| Pre-11.1 replay | idempotency key minted by a pre-11.1 build | 422 `idempotency-key-reuse` (hash inputs grew destination — 10.2 precedent, pinned EXPECTED in test) | 422 |

</frozen-after-approval>

## Code Map

- `wms-be/src/shared/db/schema.ts:130-145` -- `warehouses` — add `origin_*` columns (7 text, nullable)
- `wms-be/src/shared/db/schema.ts:1518-1553` -- `orders` — add `destination_*` columns (7 text, nullable); no FKs (codebase convention), pincode text not int
- `wms-be/drizzle/` + `drizzle/meta/_journal.json` -- migration `0030_shipment_addresses.sql`; additive, no data statements; `db:verify` must round-trip
- `wms-be/src/modules/outbound/order.command.ts:118-129` -- `CreateOrderCommand` gains `destination?: AddressInput`; validation slot: preflight after replay, beside `assertLines` (:277); `destination` added to BOTH hashes (:255-268, fixed key order); `OrderSnapshot` header (:158-171) gains `destination: AddressSnapshot | null`
- `wms-be/src/modules/outbound/outbound.dto.ts:152-246` -- `AddressDto` (nested, `@ValidateNested`) + `destination` on `OrderDto`/`OrderResponse`/`OrderListResponse`; controller arm annotations at `outbound.controller.ts:77-85` gain nothing new (400 already declared)
- `wms-be/src/modules/tenancy/tenancy.dto.ts:46-58` + `tenancy.controller.ts:137` -- `CreateWarehouseDto` gains required `origin` (nested `AddressDto`); `WarehouseResponse` gains `origin`; warehouse.command passes it through
- `wms-be/test/orders.spec.ts` + new `test/shipment-addresses.spec.ts` -- arm tests (atomicity, pincode), replay-break pin (EXPECTED 422, `test/picking.spec.ts` precedent)
- `wms-fe/src/lib/api/generated/` -- regenerate via `bun run api:generate`; never hand-edit
- `wms-fe/src/components/outbound/outbound-orders.tsx:110-260` -- `OrderCreateForm`: destination fieldset (useState per field, existing outcome pattern); destination echoed in the orders list row
- `wms-fe/src/components/settings/warehouse-create-form.tsx:32-100` -- origin fieldset in the existing form
- `wms-mobile/src/api.ts:60` -- NO CHANGE: `(await response.json()) as T` structural cast ignores new fields

## Tasks & Acceptance

**Execution:**
- [x] `wms-be/src/shared/db/schema.ts` -- add 7 `destination_*` text columns to `orders` and 7 `origin_*` to `warehouses` (all nullable), then `bun run db:generate` for `0030_shipment_addresses.sql` -- the model's spine
- [x] `wms-be/src/modules/outbound/order.command.ts` -- `destination` on the command, command-side validation (atomic + pincode regex + length ceilings → `validationFailed`), both hash inputs, `OrderSnapshot.destination` -- the boundary that keeps bad addresses out of columns
- [x] `wms-be/src/modules/outbound/outbound.dto.ts` + controller annotations -- `AddressDto`, `destination` on order DTOs -- the wire contract
- [x] `wms-be/src/modules/tenancy/*` -- required `origin` through create DTO/command/response -- warehouse origin seam
- [x] `wms-be/test/shipment-addresses.spec.ts` (new) + `orders.spec.ts` additions -- I/O matrix edge cases incl. the replay-break pin
- [x] `wms-be` -- re-export `openapi.json` -- drift guard
- [x] `wms-fe/src/lib/api/generated/` -- `bun run api:generate` -- consume the contract
- [x] `wms-fe/src/components/outbound/outbound-orders.tsx` -- destination fieldset in the create form + city/pincode on the order row -- the user enters the address
- [x] `wms-fe/src/components/settings/warehouse-create-form.tsx` -- origin fieldset -- the origin seam
- [x] meta `docs/` -- API-SURFACE.md rows, `docs/repos/wms-be/README.md` + `docs/repos/wms-fe/README.md` contract notes, PENDING.md:109 resolved -- keep the docs true

**Acceptance Criteria:**
- Given a signed-in role with `orders.manage`, when an order is created with a full destination, then the order detail and list responses echo it field-for-field.
- Given a create body with a partial or badly-shaped destination (any missing required field, or a pincode that is not 6 digits), then the API answers 400 `validation-failed` and no ledger event or order row is written.
- Given a warehouse created with an origin, then the warehouse list response echoes it.
- Given the openapi export and the FE generated client, then both regenerate with zero drift-guard failures in CI.

## Implementation Notes (2026-09-19, implementation session)

- **`AddressDto` lives in `tenancy.dto.ts`, not `outbound.dto.ts`** (the Code Map's "outbound.dto + controller annotations" was loose about placement): tenancy is the spine outbound already imports, so a shared wire DTO there avoids a tenancy→outbound import inversion. The shared address field set itself lives once in `src/shared/primitives/address.ts` (`AddressInput`/`AddressSnapshot`, `assertAddress`, `addressFingerprint`, `normalizeAddressInput`); both commands import from shared primitives, never from each other.
- **The hash keeps the `destination` key always present (`fingerprint ?? null`):** JSON.stringify drops `undefined` values, so an address that was simply OMITTED from the hash object would hash identically to a pre-11.1 payload (which lacked the key entirely) and a pre-11.1 key would still replay. With `?? null` the key is always present and every pre-11.1 hash mismatches — the deliberate break. Pinned twice in `test/shipment-addresses.spec.ts` (legacy `idempotency_keys` row → 422 `idempotency-key-reuse`; legacy `source_payload_hash` on a real ingested order → 422 `order-source-conflict`).
- **DTO required, command authoritative:** `destination`/`origin` are REQUIRED on the create DTOs (an honest OpenAPI contract for HTTP callers) while the command re-validates everything behind its replay lookup (`assertAddress` in the preflight) — the Epic 7 adapter path bypasses DTO validation. Absent address therefore passes the DTO (class-validator skips `undefined` on `@ValidateNested`) and is refused by the command with a message naming it — verified by test.
- **Snapshot→wire mapping:** the stored `line2` null (absent at create) serializes as an ABSENT optional field, not `null`, via `toAddressDto` in `tenancy.dto.ts` — the same input that omits line2 reads back omitting it. `assertAddress` returns the NORMALIZED address; callers write what it returns, never raw input.
- **The hash-break ripple is wider than the spec's test task names:** `origin` now being required at create meant **23 suites'** warehouse seeds needed an origin, and 8 order-create helpers needed a destination. The shared fixture `test/support/shipment-address.ts` (`testAddress(overrides)`) was added; suites were patched mechanically and verified by the full green run.
- **The spec's "orders.spec.ts additions" landed in `test/shipment-addresses.spec.ts` instead** — the hash/dedup/pincode arms are address concerns, and orders.spec already had its arms scattered through a 1000-line file. orders.spec only gained the seed updates. The I/O matrix (16 tests) lives in one place.
- **Migration naming:** drizzle-kit emitted a random slug; renamed to `0030_shipment_addresses.sql`, the `_journal.json` tag fixed to match, and `drizzle/meta/0030_snapshot.json` git-added (the checklist). `db:generate` after migrate reports "No schema changes".
- **Suite slug:** `useSuiteDatabase` requires `[a-z0-9_]+` — the new suite's DB is `shipment_addresses` (underscore, not hyphen).
- **FE:** `destinationSummary` / `parseDestinationFields` / `emptyDestinationFields` live in `src/lib/outbound-orders.ts` (copy lives in src/lib per convention), pinned in `outbound-orders.test.ts`; `client.test.ts` pins the destination body + origin body per wrapper. The pincode input is `type="text"` with `pattern="\d{6}"` — never a number field, so leading zeros survive. Address edits mint a fresh per-draft Idempotency-Key like any line edit.
- **No new capabilities**; mobile untouched; no new error codes — 400 `validation-failed` arms only.

## Spec Change Log

**2026-09-19, review patch round (commit 27c137e wms-be / 2537fb5 wms-fe):** the origin is normalized before hashing in `warehouse.command.ts` (G1); `assertAddress` now types every field before shaping (non-string → 400 by name, never coerced or silently dropped for line2), treats `null` like absent (400, not a TypeError), and enforces line2's 200-char ceiling (G2); ceiling + divergent-origin + warehouse pre-11.1-replay tests added (G1/G2); the FE parser takes a role label and article-safe copy, and the warehouse form parses before `setPending(true)` (G3/G4); four files gained trailing newlines. No contract change — openapi and the generated FE client are untouched by the patch.

## Review Triage Log

*28 findings (17 blind-hunter, 8 edge-case-hunter, 3 verification-gap), all verified at their cited locations on 2026-09-19. 19 route to patch in 5 root-cause groups; 9 rejected (4 false, 5 low-out-of-scope). No intent gaps, no spec changes — `review_loop_iteration` stays 0.*

| # | Layer | Finding (verified) | Verdict | Disposition |
|---|-------|--------------------|---------|-------------|
| 1 | edge | `assertAddress` never enforces `line2`'s 200-char ceiling — the ceiling loop iterates `REQUIRED_ADDRESS_FIELDS` only (`address.ts:155`); command path accepts unbounded line2 | medium | **patch G2** |
| 2 | edge | non-string `line2` is silently coerced to absent by `normalizeAddressInput` (the `typeof value === 'string' ? … : undefined` trim), losing data instead of refusing it | medium | **patch G2** |
| 3 | edge/blind | `destination: null` (not `undefined`) from a non-HTTP caller throws TypeError in `normalizeAddressInput` (`input === undefined` guard only) → 500 instead of 400 `validation-failed` | low (adapter path unbuilt, but this primitive exists for it) | **patch G2** |
| 4 | blind | non-string required fields coerce to `''` and are then reported as *missing* rather than badly typed | low | **patch G2** |
| 5 | blind | the missing-field filter's `(address[field] as string \| undefined) === undefined` arm is dead — normalized required fields are always strings | low | **patch G2** (simplify while typing the fields) |
| 6 | blind | comment `address.ts:12` claims HTTP callers are "refused by both, in the same words" — DTO (class-validator defaults) and command (custom messages) do not share wording | low | **patch G2** (reword the comment) |
| 7 | blind | no length-ceiling tests anywhere in `shipment-addresses.spec.ts` | low | **patch G2** (add ceiling tests) |
| 8 | blind/ver-gap | `warehouse.command.ts:77` hashes the RAW origin (`addressFingerprint(command.origin)`) — no `normalizeAddressInput` — while the comment above says "Normalized before hashing"; `origin: {line2: ''}` and absent `line2` hash differently, so equivalent retries answer 422 | medium | **patch G1** |
| 9 | ver-gap | origin's contribution to the warehouse payload hash is unpinned — the divergent-body test changes `name` too, so removing `origin` from the hash breaks nothing | medium | **patch G1** (test) |
| 10 | blind | no warehouse replay-break pin — the pre-11.1-key `422` matrix row is pinned for orders only; the warehouse hash grew `origin` too | medium | **patch G1** (test) |
| 11 | blind/edge | `warehouse-create-form.tsx:73` `setPending(true)` runs BEFORE the `parseDestinationFields` early return — a failed shape check leaves `pending` stuck true and the submit button permanently disabled until reload (the order form parses first, then sets pending) | medium | **patch G3** |
| 12 | blind | an origin rejection renders "The destination needs…" — the parser's copy is hardcoded to destination | low | **patch G4** (label parameter) |
| 13 | blind | "a address line 1" — the `a ${label}` builder doesn't handle the vowel | low | **patch G4** |
| 14 | blind | 4 files missing EOF newlines (`address.ts`, `0030_…sql`, `shipment-addresses.spec.ts`, `support/shipment-address.ts`) | low | **patch** |
| 15 | blind/edge | `addressFromColumns` echoes a partially-populated row (only `contactName` non-null) as a fabricated address with `''` fields | low — no writer can produce a partial row; the command writes all-or-nothing, and 4-6d will own its own write discipline | reject |
| 16 | edge | ingested redelivery with an invalid destination answers 400 before the dedup pre-check could resolve it to the prior order | false — `assertAddress` slots beside `assertLines` (`order.command.ts:309/315`), which already precedes the dedup pre-check (`:354`); a redelivery with malformed lines has always answered 400 the same way. Changing the order would be a new design, not a defect fix | reject |
| 17 | blind/edge | openapi `AddressDto.pincode` lacks `pattern`/`minLength` | low — repo convention: no `@Matches` regex is exported anywhere (the warehouse `code` dto carries only length bounds) | reject |
| 18 | blind | FE never displays the full address; origin has no read surface | false — the spec's task scoped display to "city/pincode on the order row"; full display and warehouse read surfaces are not in the intent | reject |
| 19 | blind | duplicated destination/origin fieldsets; FE hard-codes `maxLength` literals instead of sharing constants | low — extracting a shared component exceeds a direct correction; the lengths are already pinned by `outbound-orders.test.ts`, and BE/FE constants cannot be shared across repos | reject |
| 20 | blind | no DB CHECK constraints or index on the address columns | false — enforcement is deliberately command-side (the frozen Always bullet); no query filters on address columns yet | reject |

*Root-cause groups routed to patch:*
- **G1 — warehouse origin hash (findings 8-10):** normalize the origin with `normalizeAddressInput` before fingerprinting (fixing the comment), and pin both untested hash arms: same-key different-origin → 422, and a pre-11.1 origin-less key → 422 (mirror the orders tests at `shipment-addresses.spec.ts:286-311,454`).
- **G2 — `assertAddress`/`normalizeAddressInput` contract gaps (findings 1-7):** make the command validator match its stated contract — refuse non-string fields as type errors (never silently coerce or drop), treat `null` like absent, enforce the `line2` ceiling, drop the dead undefined arm, reword the "same words" comment — plus ceiling tests.
- **G3 — warehouse form stuck pending (finding 11):** parse before `setPending(true)`, matching the order form's order.
- **G4 — FE parser copy (findings 12-13):** label parameter (`destination`/`origin`) and article-safe wording; update callers and tests.
- **(no group) — EOF newlines (finding 14).**

## Design Notes

- **Flat columns, not a shared `addresses` table or jsonb:** an order's destination is point-in-time (copied at create, never re-resolved); the codebase is flat tables with no FKs; pincode must stay queryable for 4-6d rating. A jsonb `destination` would match `reference_doc`'s precedent but buys nothing here.
- **Pincode is text, always:** `110001`-style leading zeros; `/^\d{6}$/` in the command; DTO uses `@Matches` with the same regex.
- **Hash breakage is deliberate:** `destination` joins both `payloadHash` and `sourcePayloadHash` with a fixed key position. Per the 10.2 precedent accepted in `order.command.ts:243-252`, in-flight pre-11.1 keys answer 422 `idempotency-key-reuse` / `order-source-conflict` instead of replaying — pre-launch, nothing to be compatible with. Pin the break EXPECTED in a test, as `test/picking.spec.ts` does.
- **destination is `null`-able on the wire** (`AddressDto | null`): orders predating 11-1 read back as `destination: null` — the codebase's null-vs-absent convention applies.
- **No warehouse update path is a recorded gap, not an oversight:** the epic's warehouses get origin at create; a PATCH route and an edit surface are 4-6d decisions (it owns the rating semantics that would motivate them).

## Verification

**Final run (2026-09-19, post-patch, both repos at 27c137e / 2537fb5):**
- `wms-be`: jest 36 suites / **623 passed** (620 + the 3 patch tests), `tsc --noEmit` clean, `eslint` clean, `db:migrate && db:verify` round-trip OK, `openapi:export` → no diff
- `wms-fe`: `bun test` **268 pass / 0 fail** (267 + the origin-refusal pin), `tsc --noEmit` clean, `eslint` clean, `next build` OK, `src/lib/api/generated` diff-clean

**Commands (original run, pre-patch):**
- `wms-be`: `bun run db:migrate && bun run db:verify` -- expected: migrations apply, round-trip proves schema↔migrations match
- `wms-be`: `npx jest` -- expected: all suites green incl. the new address suite
- `wms-be`: `npx tsc --noEmit && npx eslint .` -- expected: clean
- `wms-be`: `bun run openapi:export && git diff --exit-code openapi/` -- expected: only the intended contract additions
- `wms-fe`: `bun run api:generate` then `git diff --exit-code src/lib/api/generated` -- expected: regenerated cleanly from the new openapi.json
- `wms-fe`: `bunx tsc --noEmit` + `bun run build` -- expected: clean

**Manual checks (if no CLI):**
- Outbound create form renders the destination fieldset; a created order's row shows city + pincode.