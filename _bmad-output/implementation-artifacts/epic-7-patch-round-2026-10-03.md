---
spec: epic-7-retro-patch-round
status: 'ready-for-dev'
context:
  - '_bmad-output/implementation-artifacts/epic-7-retro-2026-10-03.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/channels.md'
---

# Epic-7 Retro Patch Round — the three verified high-severity channel defects

Dispatches retro action item 1 (plus its riders): the verified transport/secret/test defects the epic-7 retro surfaced, one BE change-set, no public API surface change (no new routes, no DTO changes — only transport internals, one extra locked read's column, and new tests).

## Findings being fixed (each verified in the retro; sources there)

- **D1 — `GET /variants.json?sku=` is not a Shopify endpoint** (`channel-shopify-port.ts:121`; transport tests mock the fabricated URL `channel-transports.spec.ts:167`): an uncached scope 404s, the resolution cache never fills, availability dead-letters every unmapped publish.
- **D4 — disconnect revokes the Phase-1 blob** (`channels.command.ts:935-940` opens `existing.credentialSealed!` from the Phase-1 read; the Phase-2 re-lock's `CONNECTION_COLUMNS`, `channels.view.ts:85`, carries no sealed blob): a rotate committing between Phase 1 and the delete leaves the NEW credential live at the channel and stored nowhere. PENDING.md and channels.md already carry the corrected posture (landed in PR #76).
- **D9 — availability-arm shape hardening** (`channel-availability.delivery.ts:171-226` decode checks): a negative `visibleMilli` passes (`Number.isInteger` only) and posts negative availability; a non-uuid `connectionId` reaches SQL and Postgres `22P02` dead-letters the row through the retry budget; the availability arm accepts a non-numeric `locationId` (`NaN` → `location_id: null`) where the writeback arm validates (`channel-shopify-port.ts:207-211`).
- **D3 (rider) — sync worker's stall/skip/SQL never executes against a DB** (worker test `channel-sync.spec.ts:676-719` stubs `execute` and the facade; workers env-gated in suites).
- **D6 (rider) — the breaker's half-open → success → closed transition is untested** (all breaker-motion tests walk failure directions only).

## Code Map — the exact changes

### P1 — variant lookup rides GraphQL (D1)

`channel-shopify-port.ts` — replace the lookup block (`:108-137`) with one `POST {base}/graphql.json` per unresolved ref (the shared `channelHttpRequest`; same `adminHeaders`; GraphQL speaks the same `x-shopify-access-token` header):

```graphql
query VariantsBySku($query: String!) {
  productVariants(first: 10, query: $query) {
    edges { node { sku inventoryItem { legacyResourceId } } }
  }
}
```

(Verified against the published 2026-01 Admin GraphQL schema: `productVariants` takes `first` + a search `query` supporting `sku:` filters and returns a connection with `edges { node }`; `ProductVariant.sku` and `ProductVariant.inventoryItem.legacyResourceId` — "the ID of the corresponding resource in the REST Admin API" — exist. `sku` is case-sensitive.)

with `variables: { query: 'sku:"<ref>"' }` — the ref quoted so SKUs containing spaces/colons form a valid search term (embedded double quotes dropped from the ref before building the term). The arm then decides on the EDGES, client-side:

- filter edges to **exact SKU matches** (`node.sku === scope.externalRef` after trim) — Shopify's `sku:` search is tokenized, not exact-match, so the arm never trusts it; a malformed search term can only yield zero edges → `unresolved`, never a wrong mapping (the exact-match filter is the correctness boundary, the quoting is just recall);
- **0 matches** → `unresolved`;
- **>1 distinct variants** (a SKU repeated across products — Shopify permits it) → `unresolved` (ambiguous mapping is exactly the RD-6 posture: refused, never guessed);
- **exactly 1** → `inventoryItem.legacyResourceId`, validated `Number.isSafeInteger` → `resolved` + `fresh`.

Using `legacyResourceId` is the deliberate choice: it is Shopify's own documented bridge from the GraphQL resource to the numeric REST id the `inventory_levels/set.json` call needs — no gid-suffix parsing, no gid-format assumption in our code (an invalid/absent `legacyResourceId` → `unresolved`, never a guessed id).

Every OTHER arm on the port **stays REST** (inventory-levels/set, fulfillments, api_permissions) — their deprecation is real but their shape is pinned and tested; the GraphQL cutover is the retro's separate open question, not this patch.

- Response guard: a GraphQL body carrying top-level `errors` (throttling included) or an HTTP non-2xx throws through `channelHttpRequest`/parse — the existing catch marks the ref `unresolved` for this attempt (unchanged posture).
- Tests (`test/channel-transports.spec.ts`): the fake pins the REAL request shape now — POST `/admin/api/{version}/graphql.json`, the query+variables body — and the REAL response shape (`data.productVariants.edges[].node{sku,inventoryItem{legacyResourceId}}`). New arms: multi-variant ambiguity → unresolved; a non-numeric `legacyResourceId` → unresolved; a non-exact `node.sku` edge filtered out (search tokenization noise) → resolved only if one exact remains; GraphQL `errors` body → unresolved.

### P2 — disconnect revokes the re-locked row's blob (D4)

`channels.command.ts` — in the delete transaction, immediately after the Phase-2 re-lock (`:612`-area for buffers; the disconnect's own delete tx at the `existing.id` delete in `:870-885`), read the row's `credentialSealed` once (the row lock is already held; one extra selected column on the existing re-lock, no extra round trip beyond the in-tx read):

- the post-commit revoke opens **that blob**; `existing.credentialSealed` (Phase 1) remains only a typed fallback for the impossible-in-practice case of the in-tx read coming back empty — an existing connection row always carries a sealed blob (credentials are envelope-enforced by the connections migration guard); keeping the fallback makes the shape honest without a new error arm.
- the code comment at `:936-940` is rewritten to say exactly this (it currently says the opposite of the code).
- Tests (`test/channel-connections.spec.ts`): connect → rotate (credential_version bumps; the sealed blob changes) → disconnect, with the test provider's revoke arm recording the credential it received (or its opened content's version marker): the assertion is that the REVOKE received the rotated blob, not Phase 1's.

### P3 — availability-arm shape hardening (D9)

- `channel-availability.delivery.ts` `decodePublication`: add to the per-scope check `item.visibleMilli >= 0` (negative = a publisher invariant breach — V(c) is `max(0, …)` by RN-6 — and the malformed-payload posture applies: decode `null` → logged + ACKed, never retried, never posted). Add a UUID-shape check on `connectionId` (lowercase-or-capped hex, 36 chars — the repo's uuid regex where one exists): a non-uuid can only query-fail `22P02` at `integrationForDelivery`, and the malformed-payload posture (ACK, no retry burn) applies there too.
- `channel-shopify-port.ts` availability arm: adopt the writeback arm's `locationId` validation verbatim (`Number.isSafeInteger(locationId) && locationId > 0`, typed `ChannelHttpError('bad-arg', …)`) in place of the bare empty-string check.
- Tests: a negative-`visibleMilli` publication ACKs with no SQL touch (no meter row, no stamp movement); a non-uuid `connectionId` likewise; a non-numeric `locationId` refusals with the bad-arg error before any wire call.

### P4 (riders) — the two verification gaps

- **Real-DB worker tick (D3):** a new suite (or a block in `channel-sync.spec.ts`) that runs `ChannelsSyncWorker.tick()` against the suite's real DB with the real `execute`: seed ②-3 connections (one healthy, one `breaker_state = 'open'`, one whose facade publish THROWS) and assert — the enumeration SQL ran against real rows, the open-breaker connection is skipped by the WHERE (facade not called), the throwing one produced the stall/skip stamp without crashing the tick, the healthy one published. The stub-worker test at `:676` stays (it pins the plumbing contract); this adds the layer it cannot.
- **Breaker heal (D6):** one arm seeds a half-open breaker (`breaker_state` set as `retry`-moved), drives a SUCCESS delivery through the real drain path, asserts the connection row's breaker reads `closed` and the health view derives `ok`. Failure-motion pins stay as they are.

## Tasks & Acceptance

1. P1 lands with its transport tests re-pinned; `grep -rn "variants.json" src/ test/` returns **zero** hits after the patch (the fabricated URL is gone, not deprecated).
2. P2 lands with the rotate-then-disconnect revocation test; the `:936-940` comment matches the code.
3. P3 lands with the three hardening tests; the writeback arm's existing validation is NOT duplicated — extract or reference, one validation expression.
4. P4's two suites pass; the worker-tick suite runs against the real suite DB (`suite-db.ts` pattern), not stubs.
5. Full jest suite green (`bun run test -- test/`), typecheck clean, lint clean. Architecture-spec blocks untouched (no boundary moves).
6. No drift-guard change needed: no route/DTO/type changes (FE PR flow untouched; BE-only story).

## Design Notes

- **Scoped-out deliberately:** the full GraphQL cutover for the OTHER REST arms (retro open question 3 — inventory-set, fulfillments, api_permissions are equally deprecated but pin-and-tested; a cutover is its own design with its own load evidence), the relay-drain concurrency (D2 — a spine design decision, PENDING row filed), writeback quantization posture (D8 — needs the AD-9 decision first), mapping normalization (D5 — touches both writers + FE shapes; its own patch), quiet-meter posture (D10).
- **Order of arms inside P1 lookup is unchanged** (cache-first, per-ref dedupe); only the transport of the lookup changes, so the RD-6 amended result contract (`resolvedItems`/`skippedRefs`) is untouched — the delivery's cache write needs no change.
- **The revoke fix is deliberately NOT a redesign:** the post-commit posture stays (the pool-nesting gotcha was the reason RN-7 moved it); only WHICH blob the attempt opens changes.