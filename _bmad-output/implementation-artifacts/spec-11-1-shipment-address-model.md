---
title: 'Shipment address model'
type: 'feature'
created: '2026-09-19'
status: 'in-progress'
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

## Implementation Notes

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

## Review Triage Log

## Design Notes

- **Flat columns, not a shared `addresses` table or jsonb:** an order's destination is point-in-time (copied at create, never re-resolved); the codebase is flat tables with no FKs; pincode must stay queryable for 4-6d rating. A jsonb `destination` would match `reference_doc`'s precedent but buys nothing here.
- **Pincode is text, always:** `110001`-style leading zeros; `/^\d{6}$/` in the command; DTO uses `@Matches` with the same regex.
- **Hash breakage is deliberate:** `destination` joins both `payloadHash` and `sourcePayloadHash` with a fixed key position. Per the 10.2 precedent accepted in `order.command.ts:243-252`, in-flight pre-11.1 keys answer 422 `idempotency-key-reuse` / `order-source-conflict` instead of replaying — pre-launch, nothing to be compatible with. Pin the break EXPECTED in a test, as `test/picking.spec.ts` does.
- **destination is `null`-able on the wire** (`AddressDto | null`): orders predating 11-1 read back as `destination: null` — the codebase's null-vs-absent convention applies.
- **No warehouse update path is a recorded gap, not an oversight:** the epic's warehouses get origin at create; a PATCH route and an edit surface are 4-6d decisions (it owns the rating semantics that would motivate them).

## Verification

**Commands:**
- `wms-be`: `bun run db:migrate && bun run db:verify` -- expected: migrations apply, round-trip proves schema↔migrations match
- `wms-be`: `npx jest` -- expected: all suites green incl. the new address suite
- `wms-be`: `npx tsc --noEmit && npx eslint .` -- expected: clean
- `wms-be`: `bun run openapi:export && git diff --exit-code openapi/` -- expected: only the intended contract additions
- `wms-fe`: `bun run api:generate` then `git diff --exit-code src/lib/api/generated` -- expected: regenerated cleanly from the new openapi.json
- `wms-fe`: `bunx tsc --noEmit` + `bun run build` -- expected: clean

**Manual checks (if no CLI):**
- Outbound create form renders the destination fieldset; a created order's row shows city + pincode.