---
title: 'Web inputs for GSTINs and line prices'
type: 'feature'
created: '2026-10-03'
status: 'done'
route: 'dispatch'
baseline_commit: '30771565c05f4cc2c028ac8a34994f291f153704'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-8-context.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/invoicing.md'
  - 'docs/design/modules/outbound.md'
  - 'docs/design/modules/tenancy.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Since 8-1 the backend has accepted these fields, all optional:
- a tenant GSTIN at registration;
- a warehouse GSTIN at warehouse create;
- a consignee GSTIN and per-line `ratePaise` at order create.

No web form collects any of them. An order entered in the app therefore always produces an invoice parked on `supplier-gstin` (and `unpriced-line` unless priced later). A tax invoice cannot issue from the UI alone.

**Approach:** Add the four optional inputs to the three existing forms and send them on the existing create calls. Prices are entered in rupees and sent as exact paise. A blank input means "absent" and sends nothing.

**Decision (human, 2026-10-03):** **₹0 is refused** on the order form, with the copy "leave blank to price it on the invoice later". A typed rate is frozen at order creation, and an issued invoice cannot be corrected without credit notes (deferred).

## Boundaries & Constraints

**Always:**
- Each field is optional, and a blank one is omitted from the body (never `''`).
- A GSTIN is trimmed and uppercased, then shape-checked against a byte-for-byte mirror of the backend's `GSTIN_RE`.
- Rupees parse to paise only through `parseRupees`.
- On the order form, editing a rate or the consignee GSTIN mints a fresh Idempotency-Key, because both are in the backend's request hash.
- New copy and derivations live in `src/lib/` with tests.

**Never:**
- Backend changes.
- Edit routes for existing GSTINs or rates.
- Client place-of-supply logic.
- Pre-filling or remembering values.
- Fixing kit pricing: the parent rate stays inert by design (PENDING); the form only explains it.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Register with GSTIN | `' 29aapcd1234k1z5 '` | The body carries `gstin: '29AAPCD1234K1Z5'` | N/A |
| GSTIN field blank | `''` or spaces | The field is omitted | N/A |
| Malformed GSTIN | `'29ABC'` | Nothing is sent; the form's rejected banner names the field | Client refusal (server 400 as backstop) |
| Order line priced | qty 2, rate `'125.50'` | The line carries `ratePaise: 12550` | N/A |
| Line rate blank | qty 2, rate `''` | No `ratePaise` key on the line | N/A |
| Bad rate | `'1e3'`, `'12.505'`, `'-5'`, `'0'` | Nothing is sent; `Line N: …` (1-based rendered row) | Client refusal |
| Rate on an otherwise empty row | no SKU, rate `'10'` | Refused: the line needs a SKU | Client refusal |
| Rate edited after a failed submit | same draft, rate changed | The next submit sends a new key | N/A |

</frozen-after-approval>

## Code Map

- `wms-fe/src/components/auth/auth-forms.tsx`:
  - `RegisterForm` (:22-90) uses `useRouter()` (:23), so it can't be rendered under test without an App Router. Body construction moves to a pure lib function instead.
  - The per-click key (:37) is unchanged.
  - The local `rejectionReason` (:257, :270-271) already falls back to the server `detail` on `validation-failed`.
- `wms-fe/src/components/settings/warehouse-create-form.tsx`: state at :33-38, submit at :67-100, per-click key at :87, success reset at :89-91, banner at :92-96.
- `wms-fe/src/components/outbound/outbound-orders.tsx`:
  - `OrderCreateForm` (:113-180, not exported) is reached by rendering `OutboundOrders` under an `orders.manage` role.
  - `editDraft` and `editDestination` (:129-139) reset the key.
  - `emptyRow()` is at :98; rows render at ~:290-350, with a "Remove line N" aria-label at :344.
  - Submit at :143-170; reset on success at :167-169.
- `wms-fe/src/lib/outbound-orders.ts`:
  - `DraftLine` (:428), `parseDraftLines` (:449; filled-row filter at :450).
  - `DestinationFields` and `parseDestinationFields` (:497-560) are **shared with the warehouse origin form and stay unchanged**.
  - `createOutcome` (:230).
  - Tests: `outbound-orders.test.ts`, with about 21 `{skuId, quantity}` literals.
- `wms-fe/src/lib/invoices.ts`: `parseRupees` (reuse).
- `wms-be/src/shared/primitives/gstin.ts:18`: `GSTIN_RE = /^[0-9]{2}[A-Za-z0-9]{13}$/`, case-insensitive. The BE DTO transform uppercases before matching, so client uppercasing is for consistency, not load-bearing.
- Tests:
  - `src/components/outbound/outbound-orders.test.tsx` covers only `OrderDetailPanel`, and its stub records `{method, pathname}` only. Body capture is new.
  - `cold-chain-trace.test.tsx:189` `setInput` handles inputs only; a `<select>` needs an `HTMLSelectElement` setter variant.
  - The repo has no `mock.module` precedent.

## Tasks & Acceptance

**Execution:**
- [x] `wms-fe/src/lib/gstin.ts` + `gstin.test.ts`:
  - `GSTIN_RE`, a byte-for-byte mirror with a source comment;
  - `parseGstinField(text, label) → {gstin?: string, problem: string | null}`: trim and uppercase, blank → undefined, malformed → a problem naming the label.
- [x] `wms-fe/src/lib/outbound-orders.ts` + `outbound-orders.test.ts`:
  - `DraftLine.rate?: string` (optional, so existing literals stand);
  - a row with any of SKU, quantity or rate counts as filled;
  - the rate goes through `parseRupees`; 0 is refused;
  - the problem is `Line N: …`, where N is the 1-based position in the rendered draft;
  - a blank rate yields no `ratePaise` key (assert with `'ratePaise' in line`);
  - `createOutcome` adds "N of M lines unpriced — the invoice will wait for pricing" when some lines are priced and some aren't, and "kit lines are priced per component on the invoice" when the response has `parentLineId` children.
- [x] `wms-fe/src/lib/tenancy-forms.ts` (new) + test:
  - `registerTenantBody({name, ownerEmail, password, gstinText})` → `{body} | {problem}`;
  - `warehouseBody({code, name, origin, gstinText})` → `{body} | {problem}`, built on `parseDestinationFields` + `parseGstinField`.

  The forms call these.
- [x] `wms-fe/src/components/auth/auth-forms.tsx`: the GSTIN input after the business name, sent via `registerTenantBody`.
- [x] `wms-fe/src/components/settings/warehouse-create-form.tsx` + new `warehouse-create-form.test.tsx`:
  - the GSTIN input, sent via `warehouseBody`;
  - `setGstin('')` in the success reset;
  - the banner echoes the stored `warehouse.gstin` ("GSTIN 29… — can't be changed later") when present;
  - the test asserts the body, the blank omission and the refusal.
- [x] `wms-fe/src/components/outbound/outbound-orders.tsx` + `outbound-orders.test.tsx`:
  - a per-line rate input and a "Buyer GSTIN (optional, B2B)" input in its **own state**, with an `editConsigneeGstin` that resets the key. `DestinationFields` is untouched.
  - Parse order is lines → address → GSTIN, before the key mint and `setPending`.
  - Reset on success.
  - A new harness renders `OutboundOrders` as `orders.manage`, routes `POST …/outbound/orders`, and captures the JSON body and `Idempotency-Key`.
  - The test asserts `ratePaise`, `consigneeGstin`, the omissions, and a fresh key after a rate edit following a failed submit.
- [x] GSTIN inputs everywhere: no `pattern`; `maxLength={20}`; `autoCapitalize="characters"`; `spellCheck={false}`. `parseGstinField` is the only shape gate.
- [x] Help copy, in `src/lib/`:
  - GSTIN: "Can't be changed after creation yet."
  - Rate: "₹ per base unit, before GST. Once set it can't be changed and the invoice prices from it — leave blank to price it on the invoice instead. Kit lines are priced per component on the invoice."
- [x] `docs/repos/wms-fe/README.md` (meta): the three forms now send these fields.

**Acceptance Criteria:**
- Given a tenant and warehouse created in the app with GSTINs, when an order is entered with a consignee GSTIN and every **non-kit** line priced above ₹0 and is then dispatched, then its invoice is `issued` with no `unpriced-line` or `supplier-gstin` gap. This is a manual check against the local wms-be (Verification).
- Given the FE suite, when run, then lint, test, typecheck and build pass and `check:capability-mirror` is unchanged.

## Implementation Notes

- Implementer decisions (verified against the spec):
  - `parseRupees` moved to `src/lib/rupees.ts`, re-exported from `invoices.ts`, because `invoices.ts` imports `outbound-orders.ts` (a cycle otherwise). There is still one rupee grammar.
  - `OrderLineDto` carries no rate, so the "N of M unpriced" note counts the lines as sent (`createOutcome` gains an optional third argument).
  - Only rate refusals carry the `Line N:` prefix; the existing SKU and quantity messages are unchanged.
- The manual end-to-end check (Verification) was **not run**: the human chose to ship on the automated coverage (770/770 FE tests, including request-body assertions for all three forms). It remains a worthwhile smoke test after merge.
- Baseline: wms-fe `30771565c05f4cc2c028ac8a34994f291f153704` (frontmatter `baseline_commit`). Work happens on `feat/8-1c-web-gstin-and-price-inputs` in wms-fe; the meta contract edit is uncommitted in WMS-Meta.

## Spec Change Log

## Review Triage Log

*Design review, 2026-10-03: one adversarial reviewer, code-verified. 15 findings, all verified and amended above.*

| # | Severity | Finding | Disposition |
|---|----------|---------|-------------|
| 1 | medium | `context:` missed the required design docs | Added SYSTEM-DESIGN, IMPLEMENTATION-GUIDE, FE SYSTEM-DESIGN, outbound and tenancy |
| 2 | high | `DestinationFields` is shared with the warehouse origin form, so "via editDestination" would add a buyer GSTIN to the warehouse form | Consignee GSTIN in its own state; `DestinationFields` untouched |
| 3 | medium | Native `maxLength`/`pattern` would truncate or block a padded paste | No `pattern`; `maxLength` 20; parse is the only gate |
| 4 | low | Client uppercasing is cosmetic (the BE transform uppercases) | Stated in the Code Map; the regex is mirrored byte-for-byte |
| 5 | medium | ₹0 undecided; a typed rate is frozen forever | Human decision: refuse ₹0 |
| 6 | medium | The rate's permanence was hidden from users | Help copy says so |
| 7 | medium | A kit-line rate is silently inert | Copy plus an outcome note; Boundaries |
| 8 | medium | A rate-only row vanished; "line N" was undefined | A rate counts as filled; 1-based rendered row |
| 9 | high | The AC could fail with every task done, and body tests don't prove issuance | AC narrowed to non-kit, > ₹0; manual end-to-end check |
| 10 | medium | No order-form body-capture harness exists | A new harness task |
| 11 | medium | `RegisterForm` can't be rendered under test (`useRouter`) | Body built in a pure `src/lib` function |
| 12 | low | Register/warehouse key lifetime and success echo implicit | Per-click keys unchanged; reset `gstin`; banner echoes the stored GSTIN |
| 13 | low | Refusal order and "inline problem" unspecified | Lines → address → GSTIN before the key; the rejected banner |
| 14 | low | A required `rate` breaks about 21 literals; `toEqual` can't see an absent key | `rate` optional; `in` checks |
| 15 | low | No client rate ceiling; an overflow faults at invoicing | Accepted: mirrors the BE bounds (safe-int); the overflow is already a PENDING data-fault row |

*Code review, 2026-10-03: three layers (blind, edge-case, verification-gap), all reported. Every finding was verified against the code.*

| # | Verdict | Finding | Route |
|---|---------|---------|-------|
| C1 | medium | `pricingNotes` counts a kit parent's inert rate as priced, so an all-priced kit order shows no warning while its invoice waits; the note's line counts also disagree with the header (edge, blind) | patch: kit-aware counting, one basis for both counts |
| C2 | medium | `RegisterForm`'s wiring is untested (only `registerTenantBody` is); none of the forms tests that a refused GSTIN leaves the button enabled (VG, blind) | patch: an `auth-forms.test.tsx` component test via `mock.module('next/navigation')` |
| C3 | low | The warehouse "echoed from the response" test's stub mirrors the request, so it cannot prove the stored value is shown (VG) | patch: a response GSTIN differing from the typed one |
| C4 | low | The order form's lines → address → GSTIN refusal order is untested (blind) | patch: a bad address and a bad buyer GSTIN together |
| C5 | low | GSTIN help copy isn't linked by `aria-describedby`, so screen readers miss the permanence warning (blind) | patch: `useId` + `aria-describedby`, as on the rate inputs |
| C6 | low | `frontend/IMPLEMENTATION-GUIDE.md` idempotency-key line refs moved and the new shared modules are unrecorded (blind) | patch: update the refs; note `gstin.ts`, `rupees.ts`, `tenancy-forms.ts` |
| C7 | low | A wholly unpriced order gets no "invoice will wait" note (edge, blind) | defer: the pre-existing outcome copy, not caused by this change |
| C8 | medium | The invoice pricing panel (`parseRateDraft`) still accepts ₹0 while the order form refuses it (blind) | defer: pre-existing 8-1b surface; needs a human decision |
| C9 | low | The `GSTIN_RE` mirror test compares to a literal, so backend drift goes undetected (VG) | defer: a cross-repo drift guard with 8-2's regex change |
| C10 | false | New files untracked, so the build breaks (blind, edge) | reject: expected before commit; step 5 stages all |
| C11 | low | A rate × quantity product can exceed the safe integer (edge) | reject: accepted in design triage #15 (mirrors the BE; a PENDING data-fault row) |
| C12 | low | Rate and GSTIN inputs are editable while pending, so the success reset wipes an edit (edge) | reject: the form's existing pattern for every input; a ~100 ms window |
| C13 | low | The register and order forms don't echo the stored GSTIN (blind) | reject: a warehouse-only echo was decided in design triage #12 |
| C14 | low | Comma or ₹-prefixed rate input is refused with generic copy (blind) | reject: refused safely with an example; leniency adds parser surface |
| C15 | false | A case-only GSTIN edit mints a new key (blind) | reject: a fresh key on an identical payload is safe |
| C16 | low | `submitCreate` finds the form by label (blind) | reject: no failure today; a style preference |

## Design Notes

- **Mirror the GSTIN shape; the server decides.** This follows the `PINCODE_RE` precedent: the client checks shape only, and the checksum and state validity stay server-side (8-2's regulatory pass).
- **One rupee grammar.** `parseRupees` is shared with the invoice pricing panel.
- **Body builders in `src/lib`.** They make the register and warehouse bodies testable without an App Router, and keep the "build it from the parse" rule in one place.

## Verification

**Commands:**
- `bun run lint && bun run test && bun run typecheck && bun run build` (wms-fe): green.
- `bun run check:capability-mirror` (wms-fe): unchanged (34).

**Manual checks:**
- Against the local wms-be with `OUTBOX_RELAY_POLL_MS` set:
  1. Register with a GSTIN.
  2. Create a warehouse with a GSTIN.
  3. Enter an order with a buyer GSTIN and every non-kit line priced.
  4. Pick, pack and dispatch it.

  On `/compliance` the invoice should read Issued, with no `unpriced-line` or `supplier-gstin` gap.
