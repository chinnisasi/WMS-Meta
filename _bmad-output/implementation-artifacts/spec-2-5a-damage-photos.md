---
title: '2-5a damage photos — a tenant-isolated, S3-backed attachment foundation, and its first consumer: damage photos on a receipt line, captured offline on the handheld, viewed and added on the web, visible to the client in the portal'
type: 'feature'
created: '2026-10-23'
status: 'ready-for-dev'
route: 'dispatch'
review_loop_iteration: 0
context:
  - '_bmad-output/implementation-artifacts/epic-2-context.md'
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/modules/inbound.md'
  - 'docs/design/modules/tenancy.md'
  - 'docs/design/mobile/SYSTEM-DESIGN.md'
  - 'docs/design/mobile/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/frontend/SYSTEM-DESIGN.md'
  - 'docs/design/frontend/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/API-SURFACE.md'
  - 'docs/design/DEPLOY.md'
  - 'docs/design/PENDING.md'
  - '_bmad-output/implementation-artifacts/spec-2-4a-damaged-and-short-receipt-quantities.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A receipt line can record damaged units (2-4a) but not the evidence. A 3PL's vendor or carrier claim, and the client's acceptance of a damaged delivery, rest on photos taken at the dock. The system has no general file storage: the only S3 code is the ledger-anchor WORM copy (`inventory/ledger-anchor-worm.ts`), and audit exports keep their bytes in Postgres (`audit_export_files`). 1.6 (SDS, licence scans) and 4.4 (label PDFs, POD) are waiting on the same storage (the 1.6 SDS entry in `deferred-work.md`, `PENDING.md:350`).

**Approach:**
- A reusable **attachments** foundation:
  - one `attachments` table in a new `attachments` module, with tenant and client RLS;
  - a `FileStore` port with modes `none | local | s3`;
  - a pure-JS image sanitizer: sniff the type from the bytes, check the structure, strip metadata;
  - downloads through short-lived presigned GET URLs;
  - retention, plus a sweep job.
- Its first consumer, **damage photos on a GRN line**:
  - **Handheld:** photos are taken at the dock, sealed on the device, and queued as their own ops behind the receipt. The receipt never waits on, or fails because of, a photo.
  - **Web:** photos are viewed, added and removed on the GRN row.
  - **Portal:** the client sees them in a new, minimal **Receipts** view.

**Decisions (recommended, taken autonomously):**
1. **Split.**
   - 2-5a = the foundation plus receipt damage photos, across backend, web, handheld and the portal read.
   - Deferred, each inserted beside a related `deferred-work.md` entry:
     - 1.6 SDS and licence-certificate documents (a PDF arm and malware scanning);
     - 4.4 client label PDFs and outbound documents/POD;
     - 2-5a follow-ups: a per-client "photo required" policy, QC-inspection and return-receipt evidence, thumbnails, quotas and metering, offboarding purge, and video via presigned multipart upload.
2. **Upload through the API; download presigned.**
   - This is a deliberate deviation from "presigned direct upload".
   - The server must sniff and strip the bytes before anything is stored. A direct PUT would make it download, rewrite and re-put every object anyway.
   - One keyed multipart request per photo is the simplest op for the device WAL to replay. It also means no bucket CORS, and `local` and `s3` behave identically.
   - Size cap: ≤ 10 MB, held in memory by multer and never written to disk. That suits 6-2c's read-only root filesystem.
   - Downloads: `GET` returns presigned S3 URLs (TTL `ATTACHMENT_URL_TTL_SECONDS`, default 300). S3 serves the bytes; the API never proxies them.
3. **Allowed types and limits.**
   - Types: `image/jpeg`, `image/png`, `image/webp`, decided by **magic bytes**. The declared type and the filename are ignored.
   - Refused: HEIC, SVG, GIF, PDF and everything else (415 `attachment-type-unsupported`).
   - Limits: ≤ 10,485,760 bytes (422 `attachment-too-large`), and each side 1..8,000 px read from the header (422 `attachment-content-invalid`).
   - The sanitizer **never decodes pixels**. It walks the container structurally:
     - JPEG: the segments up to SOS, then to EOI;
     - PNG: the chunks with their CRCs, IHDR first and IEND last;
     - WebP: the RIFF chunks.
   - It drops EXIF/XMP/IPTC/comments/text chunks (APP1, APP13, COM; `eXIf`/`tEXt`/`zTXt`/`iTXt`/`tIME`; WebP `EXIF`/`XMP `, fixing the RIFF size and the VP8X flags). It keeps ICC and APP0/APP14, and drops any bytes after EOI/IEND (polyglot tails).
   - A malformed structure is 422 `attachment-content-invalid`.
   - Only these three sanitized raster types are ever served `inline`, with the `Content-Type` fixed at put, from the bucket's own origin. Any future type is served `attachment` (Never list).
4. **Clients re-encode; the server enforces.**
   - Handheld: `expo-image-manipulator` re-encodes to JPEG q0.7 with the long edge ≤ 1,600 px. This bakes in the orientation and drops EXIF/GPS.
   - Web: `createImageBitmap(file, {imageOrientation: 'from-image'})` → canvas → JPEG 0.85, long edge ≤ 2,560 px.
   - The server's strip is the guarantee. Client re-encoding is only for size and orientation: a caller that skips it gets its photo stored as sent, minus metadata.
5. **Offline linkage — the photo's ULID, bound in either order.**
   - The handheld mints a ULID per photo at capture. It is that photo op's `Idempotency-Key` and the attachment's `client_ref`.
   - `grn.submit` lines carry `photoRefs`.
   - Binding is **order-independent**:
     - a photo uploaded first is `staged`, and the receipt that names it attaches it;
     - a receipt that lands first creates an `awaited` placeholder on its line, and the photo that arrives later fills it.
   - The device enqueues the receipt **first**, then the photos, so a receipt is never behind a photo in FIFO.
   - A receipt is never refused because of a photo. A ref that is unknown or already bound elsewhere is skipped silently.
6. **Storage port.**
   - `FILE_STORE=none|local|s3`, the env-switched-port rule (guide §8). A MODE, never a credential.
   - `none` (default; CI and tests):
     - uploads answer 503 `file-storage-unavailable`, after the replay lookup, so a committed op still replays;
     - the device snapshot says `receiptPhotos.enabled: false`, so the camera button is hidden;
     - reads list no URLs.
   - `local`: the S3 adapter against the dev docker-compose MinIO (`FILE_STORE_S3_ENDPOINT`, path-style). The boot refuses it when `NODE_ENV=production`.
   - `s3`: requires `ATTACHMENTS_S3_BUCKET` and a valid `AWS_REGION` (default ap-south-1), or the boot fails.
   - Object key: `tenants/<tenantId>/attachments/<attachmentId>`. It holds no names, codes or client data.
   - The e2e suites use an in-memory fake assigned to the port field.
7. **Authority.**
   - Device upload: the `grn.submit` gate (`assertDeviceOperatorInTx`, a floor role), with no capability.
   - Web add: the new `receipt.attach` (owner, ops_manager, operator).
   - Remove: the new `attachments.remove` (owner, ops_manager).
   - Staff reads: any member.
   - Portal reads: only `attached` photos of the session's own client.
   - Both capabilities are mirrored in `wms-fe/src/lib/users.ts`.
8. **Limits.**
   - ≤ 10 photos per line (`attached` + `awaited`).
   - ≤ 10 `photoRefs` per line and ≤ 50 per receipt, every ref unique across the receipt. This is a 400 above the transaction.
   - A web add past 10 is 409 `attachment-limit-reached`. A receipt's refs never exceed the cap because of the shape check.
9. **Retention.**
   - `attached` photos live as long as the GRN, which is never deleted.
   - Removal is **soft**: status `removed`, with a reason of 1–200 characters. The row and audit stay; the bytes are purged 30 days later (`purged_at`).
   - `staged` rows never bound: the object and the row are deleted after 30 days.
   - `awaited` rows never filled: they become `expired` after 30 days, shown as "never arrived".
   - `uploading` reservations: the object and the row are deleted after 1 hour.
   - The worker `AttachmentSweepWorker` runs on `ATTACHMENT_SWEEP_POLL_MS`, at most 100 rows per tenant per tick. It is safe to run twice, since every step is idempotent and conditional on status.
10. **Portal.**
    - The portal has no GRN view (`portal-inbound.tsx` has only ASNs and POs). Roadmap 2.9 owns "GRNs in the portal".
    - 2-5a adds the minimal read 2.9 will extend:
      - `GET …/portal/inbound/goods-receipts`;
      - `GET …/portal/inbound/goods-receipts/{grnId}`, the lines with their condition and the `attached` photo URLs.
    - 2.9 keeps the printable GRN document and the receipt notifications.
11. **No outbox event and no notification.** Nothing consumes one yet.
    - Audit: `receipt_photo.uploaded` (device), `receipt_photo.added` (web) and `receipt_photo.removed`, with the new target type `attachment`.
    - `grn.submit`'s own audit is unchanged.
12. **Handheld at rest (AD-15).**
    - Each photo is sealed with the offline-store key (the existing `v1:` envelope) into `documentDirectory/receipt-photos/<ref>.sealed`, written **before** its op is enqueued.
    - It is deleted when its op settles or is rejected, and on reset (before the key is dropped). At store init, any file that no queued op references is deleted.
    - Capture is refused, never the receipt, when ≥ 200 photos are queued or free disk is < 200 MB.

</frozen-after-approval>

## Design Review Amendments

Design review, 2026-10-23: a claims check against origin/main (K1–K26) and a blind review (B1–B24). These amendments override the frozen decisions where they differ. Recommended, taken autonomously. The triage is in `## Review Triage Log`.

**A1 — Ref serialisation (K1).**
- `uploading` reservations carry **no** `client_ref`.
- The upload's final transaction and the receipt claim both take `pg_advisory_xact_lock(hashtext('attachment-ref:' || tenant_id), hashtext(ref))` **before** reading the ref's row.
- The claim takes its locks with refs sorted, as the last locks of `grn.submit`: it runs immediately before the outbox append (`receiving.command.ts:2010`), after every ledger append.
- Tests: parked-waiter races in both orders (`raceTwice` + `waitParked`), receipt-first and photo-first. Each yields exactly one `attached` row.

**A2 — The fill and conflict table (K2, B6; supersedes decision 5's "skipped" wording for these states).** What the upload's final transaction does with the ref's row:

| Ref row | Upload's final tx |
|---|---|
| none | the reservation becomes `staged` (and gets `client_ref`) |
| `awaited` or **`expired`** | FILL: delete the reservation first (A9's unique key), copy the object fields in, set `attached` + `uploaded_at` |
| `attached` / `removed` / `staged` | if `sha256` of the raw upload equals the row's `raw_sha256`: answer the replay-shaped body; else 409 `attachment-ref-conflict` |
| `discarded` | treated as none: a new `staged` row (the old row keeps its history) |

A receipt rejected outright, or a line sent to review, leaves its refs `staged`. The rows that can re-bind them are:
- a device-uploaded `grn.submit` review row (Apply);
- `grn.shelf-life-refused` (Apply);
- `grn.licence-refused` (Apply).

`grn.lines-refused` is Discard-only (`sync-report.command.ts:174`), so its refs stay staged until A10's sweep.

The migration probes the shapes each transition produces: `expired` → `attached`, and a cancelled `awaited` → `removed` with no object (A13).

**A3 — Review-row carry (K3; supersedes the Code Map line on `clientRefusalLines`).**
- `photoRefs` (only when non-empty) go into the **three** review-row payload builders only: `grn.lines-refused`, `grn.shelf-life-refused`, `grn.licence-refused`.
- `clientRefusalLines` and `RejectedGrnLineDto` are unchanged.
- An Apply passes the stored refs back through `grn.submit` and binds them (A12's device rule).

**A4 — Portal reads (K4; supersedes decision 10's placement).**
- `portalGoodsReceiptsInTx` and `portalGoodsReceiptInTx` live in `portal-inbound.ts`.
- They are exposed as `InboundFacade.portalGoodsReceipts` / `portalGoodsReceipt`, beside `portalAsn` (`inbound.facade.ts:174`), and registered in `PORTAL_READS` under `inbound.facade.ts` (`test/architecture.spec.ts:2269`).
- Presigning happens inside the facade, after the stamped read.
- The local `assertUuidParam` unions widen: `receiving.controller.ts:599` gains `'lineId' | 'attachmentId'`, and `portal.controller.ts:555` gains `'grnId'`.
- **The portal shows removed photos** as "Removed by the warehouse": no URL, no reason, no remover (B14).

**A5 — Caps on the device (K5).**
- The snapshot's `receiptPhotos` is `{enabled, maxPerLine: 10, maxPerReceipt: 50, maxBytes}`.
- `canConfirm` (`draft.ts:385`), `confirmBlocker` and `confirmPayload` enforce both caps, so a draft over either cannot be confirmed (a device test pins it).
- **The server caps count `attached` + `awaited` rows** (K21 below): per line ≤ 10 and per receipt ≤ 50, enforced on the claim (by shape) and on a web add (409 `attachment-limit-reached`).

**A6 — Partial unique conflicts (K6).**
- Every insert against a partial unique index uses `onConflictDoNothing({ target, where })` with the index's predicate. The precedent is `pack.command.ts:339-342`.
- Applies to `client_ref` (the claim's `awaited` insert, the `staged` conversion) and `upload_key` (the reservation).
- A seam test covers each.

**A7 — The capturing operator (K7, B4; supersedes decision 7's device authority).**
- Each photo op carries its capturing operator. The device sends it with the **device credential** (`deviceToken`), never the badge token, with `x-op-operator` set to that operator.
- The server:
  - requires `x-op-operator` (400 `validation-failed`);
  - runs `assertDeviceOperatorInTx(tx, t, deviceId, opOperator)` (`device-operator.ts:23`, locking the device row);
  - requires `devices.operator_user_id` = `opOperator` (403 `role-denied`).
  - `opOperator` is in the hash.
- Using the device credential skips the badge-session `operator-mismatch` check in `device-session.guard.ts:88-99`.
- On the device, photo ops are **exempt from the operator-changed hold** (`engine.ts:123-133`), because they move no stock. A photo still uploads when the capturer has badged out, or when another operator is badged in.

**A8 — Atomic enqueue (K8, B2; supersedes decision 5's "then the photos").**
- New `OfflineStore.enqueueOps(ops[])` appends the receipt op and all its photo ops in **one** SQLite transaction (`withTransactionSync`, `outbox-store.ts:28`), through `rowValuesFor` and `replayGate.registerAppend`. `InMemoryOutboxStore` mirrors it.
- Crash test: a kill between the appends leaves either all of them or none.

**A9 — Plaintext on disk (K9, B3, B8).**
- Capture order:
  1. `takePictureAsync` writes into a dedicated `cacheDirectory/receipt-photo-tmp/`;
  2. the manipulator output goes there too;
  3. its bytes are sealed and written to `<ref>.sealed.tmp`, then renamed to `<ref>.sealed`;
  4. **then** the camera and manipulator files are deleted.
- The temp dir is wiped at store init and at reset.
- Upload is from **in-memory bytes**: the sealed file is opened to a `Uint8Array`, and the multipart body is built by hand as a `Uint8Array` with its boundary. There is no decrypted temp file.
- A device test against the dev server must prove RN `fetch` sends a typed-array body byte-exact. If it cannot, stop and record it; do not fall back to a plaintext file.
- A test after a simulated kill at each step finds no plaintext outside the temp dir, and an init wipe that clears it.

**A10 — Retention and the sweep (K11, K12, B9, B10, B11, B14; supersedes decision 9's mechanics).**
- **New terminal status `discarded`**, for an `uploading` or `staged` row whose bytes are deleted. The row is kept; it is not hard-deleted.
- **Ages run on named timestamps:**

  | Rows | Clock | Deadline |
  |---|---|---|
  | `uploading` | `created_at` | 1 h |
  | `staged` | `created_at` | `ATTACHMENT_PURGE_DAYS` (default 30) |
  | `awaited` → `expired` | `created_at` | `ATTACHMENT_PURGE_DAYS` |
  | `removed` purge | `removed_at` | `ATTACHMENT_PURGE_DAYS` |

- **Every transition sets `updated_at` explicitly.**
- **The sweep, per arm:**
  1. claim ≤ 100 rows `FOR UPDATE SKIP LOCKED`;
  2. re-check status and age;
  3. move to the terminal state (`discarded` / `expired`; `removed` stays) and commit;
  4. then `FileStore.delete`;
  5. then a second short transaction sets `purged_at`.
- A delete that fails leaves `purged_at` null and is retried on the next tick.
- **Shared objects:** before deleting, the sweep confirms no other live row holds the same `object_key`. The UNIQUE partial index `attachments_tenant_object_key_unique (tenant_id, object_key) WHERE object_key IS NOT NULL AND purged_at IS NULL` makes that structural.
- **Referenced refs survive (K11):** the sweep never discards a `staged` ref named by an **open** `rejected_ops` row's payload. The query is a `jsonb_path_exists` over `payload`'s line `photoRefs`, scoped to `status = 'open'`, with an `EXPLAIN` of the real query per §9. A test covers it.
- **Race with an upload:** an upload's final transaction that finds its reservation `discarded` answers 503 `file-storage-failed`. The retry makes a new reservation, because the `upload_key` uniqueness is only `WHERE status = 'uploading'`. A race test runs the sweep against the final transaction.
- **Audit:** each purge writes `receipt_photo.purged` (actor `SYSTEM_ACTOR_ID`, an unkeyed sweep — outside the keyed rule).
- **Legal hold** is not built. The risk: a removed photo needed in a dispute is purged after `ATTACHMENT_PURGE_DAYS`. Deferred.

**A11 — Sweep discovery (B12).**
- `AttachmentSweepWorker.tick` discovers tenants on the read-only `AUTH_DATABASE`, exactly as `AuditExportWorker.tick` does (`jobs.module.ts:1400-1414`, `select distinct tenant_id … order by tenant_id`), over the sweepable predicate.
- Then one `AttachmentsFacade.sweep(tenantId, now)` per tenant, each in its own try/catch.
- New index `attachments_sweep_discovery_idx (status, created_at)`, `IF NOT EXISTS`, outside any `DO`.
- No `tenantsWithSweepWork()` facade method (that supersedes the Code Map).

**A12 — Sanitizer allow-lists (K13, B16; supersedes decision 3's drop-list).** Every format is an **allow-list**; anything not listed is refused (422 `attachment-content-invalid`) or dropped as stated.
- **JPEG:**
  - Kept: SOI; APP0 `JFIF\0` (a JFXX thumbnail extension is dropped); APP2 only when `ICC_PROFILE\0` (any other APP2, e.g. MPF, is dropped); APP14 `Adobe`; DQT, DHT, DRI, SOF0/SOF1/SOF2, SOS, RST0–7, EOI.
  - Dropped: every other APPn (APP1 EXIF/XMP, APP13 IPTC) and COM, **wherever they occur, including between progressive scans**.
  - Every other marker refuses (SOF3/5–15, arithmetic coding, DNL…).
  - The walk handles multiple scans by parsing the entropy-coded data to the next real marker (skipping `FF00` and RSTn), finds EOI that way, and drops everything after it.
- **PNG:**
  - Kept: IHDR (first), PLTE, IDAT, IEND (last), tRNS, gAMA, cHRM, sRGB, iCCP, sBIT, pHYs, bKGD.
  - Dropped: any other ancillary chunk.
  - Refused: an unknown **critical** chunk, a bad CRC, or **APNG** (`acTL`/`fcTL`/`fdAT`) → 415.
- **WebP:**
  - Kept: VP8, VP8L, VP8X, ICCP, ALPH.
  - Dropped: EXIF and XMP (the VP8X flags are rewritten, and the RIFF size too).
  - Refused: animation (`ANIM`/`ANMF`, or the VP8X animation flag) → 415. Any other chunk refuses.
- **Fixtures:** a progressive JPEG with APP13 between scans, an MPF JPEG (iPhone/Android), a JFXX thumbnail, an APNG, an animated WebP — plus the existing list.

**A13 — Statuses and CHECKs (K20, K21; supersedes the Design Notes CHECK list).** The migration CHECKs are rewritten in Design Notes:
- the owner is null on `uploading` (web reservations too; the owner is set at finalize);
- `awaited` can be cancelled to `removed` with no object (by `receipt.photo-remove`), which relaxes `_object_pairing`;
- every implication is its own named CHECK, so each refused probe names its arm;
- accepted probes include `uploading` (device and web), `expired`, an expired-then-filled `attached`, a cancelled `removed`, and `discarded` + `purged_at`.

**A14 — Downloads and responses (K14, B19).**
- **Filename:** `Content-Disposition` is built by the server, ASCII only: `<grnCode>-L<lineNo>-<k>.<ext>`, sent as `inline; filename="…"; filename*=UTF-8''…` (RFC 5987). It never comes from `originalname`.
- **Content type:** `ResponseContentType` is signed from the DB `content_type` column.
- **Expiry:** `urlExpiresAt = min(now + ATTACHMENT_URL_TTL_SECONDS, credentials.expiration)`, with the credentials read from the client's provider. A URL never outlives the task role's session.
- **No stored idempotency snapshot contains a URL:**
  - device upload → 201 `{ref, status}`;
  - web add → 201 `{attachment: {id, grnLineId, status, contentType, byteSize, width, height, capturedAt, uploadedAt, source}}`;
  - remove → 200 the same shape with `status`, `removedAt`.
  - URLs are only in the GET reads.
- **Bucket name:** a random suffix, not the account id (infra).
- **Integration test:** `test/file-store-minio.spec.ts`, run in a new CI job `minio-integration` with a pinned MinIO service. It skips itself when `FILE_STORE_MINIO_TEST_ENDPOINT` is unset. It puts, presigns, and checks a plain `fetch` returns 200 with the signed `Content-Type` and disposition.

**A15 — Request order and multer limits (K15).**
- Nest runs guards → interceptors (multer) → pipes → handler. So the session guard refuses an unauthenticated or wrong-family upload **before** any body is buffered.
- The idempotency-key parse runs in the handler, after multer: a missing key costs one buffered body and answers 400.
- `FileInterceptor('file', { limits: { fileSize: 10_485_760, files: 1, fields: 4, fieldSize: 256, parts: 6 } })`. A breach maps to 422 `attachment-too-large` (size) or 400 `validation-failed` (counts), via `AttachmentUploadFilter`.

**A16 — Back-pressure (K16, B18).**
- A process-wide semaphore of 4 around sanitize + put. With no slot free → 503 `file-storage-busy` (device: unreachable, retried).
- A per-device cap of 200 `staged` unbound rows → 429 `attachment-staging-limit` (device: unreachable within the photo lane).
- The memory budget goes in the infra interface.

**A17 — Claim scope (K17).**
- The claim binds a `staged` row only when its `device_id = command.deviceId`. An Apply passes the rejected op's `device_id`, so it re-binds that device's photos.
- Correction: a ULID carries **80 random bits** (plus a 48-bit time). Scope is the tenant, the device and the ref.

**A18 — Hash and replay before sanitizing (K18; supersedes the protocol's step 0).**
- The fingerprint uses `rawSha256`, the SHA-256 of the **raw** upload bytes.
- Order:
  1. above the transaction: shape (key, file present, multer, `capturedAt`), then the hash;
  2. Tx A: authority → replay → mode → sanitize (415/422) → reservation.
- A replayed key never re-sanitizes, so a later sanitizer version cannot refuse a committed op.
- The reservation stores `upload_hash` and `raw_sha256`.

**A19 — The photo op on the device (K19, B5).**
- Payload `{ref, capturedAt, grnOpId, lineIndex}`. No bytes; the row stays far under the 32 KB cap.
- `PAYLOAD_FIELDS['receipt-photo.stage']` (`sync-report.command.ts:335`) lists `ref`, `capturedAt`, `grnOpId`, `lineIndex`.
- **File lifecycle:**
  - settled → the file is deleted;
  - finally rejected → deleted;
  - quarantined (device revoked) → kept with its retained op until reset;
  - the init sweep keeps every file named by a queued **or retained** op.
- **503 `file-storage-unavailable`** is unreachable (kept, retried) while the op is younger than 7 days, then rejected with its retraction. The file is kept until that final rejection.

**A20 — Remove (K22, K25, K21; supersedes decision 7's capability name).**
- The capability is `receipt.photo-remove` (owner, ops_manager).
- Fingerprint `{tenantId, surface: 'web-photo-remove', grnId, attachmentId, reason}`.
- It removes an `attached` row, or cancels an `awaited` one (no object).
- Staff still see removed photos, as status + remover + reason, with no URL.
- **A URL issued before a removal works until it expires (≤ 300 s). Accepted in writing.**

**A21 — Local mode (K23).**
- MinIO credentials come from the SDK default chain. `.env.example` names `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` with no values.
- `FILE_STORE_S3_ENDPOINT` is where the API puts. Optional `FILE_STORE_PUBLIC_ENDPOINT` is the presign host when the BE runs inside docker.
- `deploy/compose.yml`'s production profile cannot use `local`, because the boot refuses it under `NODE_ENV=production`.

**A22 — Worker health (K24).**
- If 6-2c lands first, `AttachmentSweepWorker` calls `this.ticks.track('attachment-sweep', pollMs, 600_000)` and `this.ticks.beat()` once per tenant (6-2c A3).
- Two worker instances are safe, because every arm claims `FOR UPDATE SKIP LOCKED` and transitions conditionally. Record it in PENDING's worker audit as proven by a two-sweeper test.

**A23 — The list bound (K26).**
- The staff list returns every live row (≤ 50 by A5), plus at most the 50 newest `removed`/`expired` rows.
- The portal returns live rows plus removed placeholders under the same bound.

**A24 — Two lanes on the device (B1; an explicit, recorded exception to "no change to how the WAL orders or replays existing op types").**
- `replayOutbox` walks **non-photo ops first** in FIFO, exactly as today. Then it walks the photo ops in FIFO.
- `unreachable` in the photo lane stops only the photo lane. `revoked` still strands everything.
- A photo can therefore never hold back a receipt, a pick or a move.
- Test: storage down (photo ops kept), and a `grn.submit` queued after them still settles.

**A25 — Audit (B13, B22; supersedes decision 11's list).** Actions, all target `attachment` unless stated:

| Action | Written by | Actor | Reference |
|---|---|---|---|
| `receipt_photo.uploaded` | device upload | the op's operator | the upload's key |
| `receipt_photo.attached` | the claim (per staged row it binds) and a fill (per awaited/expired row) | the operator | the GRN's key / the upload's key |
| `receipt_photo.added` | web add | the user | its key |
| `receipt_photo.removed` | remove | the user | its key |
| `receipt_photo.purged` | sweep | system | — |
| `receipt_photo.ref-skipped` (target `goods_receipt`) | the claim, for a stale or foreign ref | the operator | the GRN's key |

- A skipped ref is also a structured `warn` log. The receipt's response is unchanged.
- Every keyed action is in `AUDIT_NEW_ACTIONS` with `expectAuditRow`.

**A26 — Personal data (B15).**
- The capture screen shows a hint: "Photograph the damage — avoid faces and number plates."
- The DPDP stance is in Design Notes.
- An owner-only urgent purge and operator self-removal are deferred.

**A27 — Client and warehouse on `awaited` (B17).**
- The claim's `awaited` insert takes `client_id`/`warehouse_id` from the GRN.
- A `wms_rls_probe` test shows a client-A stamp cannot see a client-B photo through the list query.

**A28 — `capturedAt` and the web (B24).**
- `capturedAt` is stored clamped to `[now − 60 d, now + 10 min]`. The hash keeps the raw value.
- New `uploaded_at` (server receive time) is set on staging and fill.
- The web dedupes its expired-URL refetch: one in flight per dialog, at most once per image error.
- The web says "HEIC photos are not supported — export as JPEG" when a file sniffs as HEIC.

**Amended Boundaries:**
- *Never* "no change to how the WAL orders or replays existing op types" now reads: existing ops keep their FIFO order and fates; photo ops drain in a second lane after them (A24), and are exempt from the operator-changed hold (A7).
- *Always*: no plaintext photo outside the dedicated temp dir after capture (A9); no URL in any stored snapshot (A14).

**Amended matrix rows:**

| Scenario | Input / State | Expected | Error handling |
|---|---|---|---|
| Late photo after expiry | `awaited` → `expired`, then the upload lands | FILL → `attached` (A2) | — |
| Ref conflict | Same ref, different bytes | 409 `attachment-ref-conflict` | Device: rejected |
| Operator gone | Capturer badged out, or another operator badged in | The photo uploads under the device credential + `x-op-operator` (A7) | Device revoked → quarantined |
| Storage off, op < 7 d | 503 `file-storage-unavailable` | Kept in the photo lane; receipts still sync (A24) | ≥ 7 d → rejected, file deleted (A19) |
| Busy / staging cap | 4 uploads in flight / 200 staged | 503 `file-storage-busy` / 429 `attachment-staging-limit` | Device: kept, retried |
| Apply after review | `grn.shelf-life-refused` / `grn.licence-refused` / device `grn.submit` row applied | Its staged refs bind (A2, A17) | `grn.lines-refused`: Discard → the refs stay staged; swept after 30 d unless an open review row names them (A10) |
| Cancel awaited | Remove on an `awaited` row | `removed` with no object | — |
| Portal, removed | A removed photo on the client's GRN | "Removed by the warehouse", no URL | — |

## Boundaries & Constraints

**Always:**
- A receipt (`grn.submit`) books exactly as today whatever happens to its photos. A request without `photoRefs` hashes and answers **byte-for-byte** as before.
- Every stored object passed the allow-list sanitizer (A12).
- Every attachment read is tenant-scoped. A portal read is two-layer (guide §7e): a `{ clientId }` stamp, plus an explicit `client_id = $client` on `attachments` and on `goods_receipt_notes`, with the lines reached only by an inner join to `skus` carrying the same predicate. `goods_receipt_notes` RLS is tenant-only (`drizzle/0013_steady_diamondback.sql:63`) and stays so.
- The S3 put and delete run **outside** every transaction. Reservation and terminal rows make every orphan sweepable without listing the bucket (A10).
- No plaintext photo on the device outside the temp dir after capture (A9). No URL in any stored snapshot (A14).

**Never:**
- No presigned upload, no bucket CORS, no server-side pixel decoding, and no thumbnails.
- No PDF, video or other non-image type. No `inline` disposition for any type outside the three.
- No hard delete of an attachment row. No change to GRN RLS.
- No SDS, licence or 4.4 documents. No photo-required policy. No QC or return photos. No legal hold. No urgent purge.
- No notification, email or outbox event.
- No change to existing ops' FIFO order or fates (the photo lane is additive, A24).

## I/O & Edge-Case Matrix

The rows below plus A's amended rows.

| Scenario | Input / State | Expected | Error handling |
|---|---|---|---|
| Offline, normal order | GRN op (line 2 `photoRefs:[P1,P2]`) then P1, P2 ops | The GRN books and its claim creates P1/P2 `awaited`; each upload fills its row | — |
| Photo first | P1 replays before its GRN | P1 `staged`. The claim attaches it (same device) | — |
| Line refused | The line goes to a review row | The refs stay `staged`. The review payload carries them (A3) | See the amended Apply row |
| Stale ref | Already attached elsewhere, unknown, or another device's | The receipt books, the ref is skipped, a `ref-skipped` audit row is written | Never a refusal |
| Bad file | SVG / HEIC / APNG / truncated / 11 MB / 9,000 px | 415 / 415 / 415 / 422 / 422 / 422. Nothing stored | Device: rejected with the retraction "Damage photo not uploaded — {reason}. The receipt is not affected."; the file is deleted; the review row is Discard only |
| EXIF/GPS | JPEG with APP1 GPS | No APP1 in the stored bytes. The stored `sha256` is of the stored bytes | — |
| S3 down | The put throws | 503 `file-storage-failed`. The reservation stays for a same-key retry | Device: kept (photo lane) |
| Same key, other bytes | A retry with a different file | 422 `idempotency-key-reuse` (also against the reservation's `upload_hash`) | — |
| Web add over cap | The line holds 10, or the receipt holds 50 | 409 `attachment-limit-reached` | — |
| Remove twice | Already `removed` | 409 `attachment-not-attached` (a same-key retry replays) | — |
| Portal, foreign GRN | Another client's or a null-client GRN id | 404 `not-found`, identical to an unknown id | — |
| URL expired | `<img>` error after `urlExpiresAt` | One deduped refetch per dialog (A28) | — |

## Code Map

**Backend** (`workspace/core/backend/wms-be`, origin/main):

Reuse:
- `src/modules/inventory/ledger-anchor-worm.ts`:
  - the mode/port/factory shape (`:25-27`, `:65`, `ledgerAnchorWormFromEnv` `:209-226`);
  - the region regex `:199`;
  - `s3ErrorCode`.
- Copy the shape; do not import it.
- Adapter unit tests use `aws-sdk-client-mock`.
- Add `@aws-sdk/s3-request-presigner` pinned to `@aws-sdk/client-s3`'s 3.1151.0.

Multipart:
- The pattern is `catalog.controller.ts:175-230`. Limits per A15.
- `AttachmentUploadFilter`, a sibling of `shared/import/upload-filter.ts`.

`grn.submit`, in `src/modules/inbound/receiving.command.ts`:
- **Hash `:659-725`:** each line's last key, after `...conditionHashFields(line)`, is `...(refs.length === 0 ? {} : { photoRefs: refs })`, in capture order. Add a new golden; the old goldens stay identical.
- **Normalise `:748-764`:** `?? []`.
- **Shape above the transaction:** ULIDs; ≤ 10 per line; ≤ 50 per receipt; unique across the receipt.
- **The claim** (settled lines only) runs **immediately before the outbox append `:2010`** (A1).
- The response and snapshot are unchanged.
- The device id passes into the claim (A17).

Review rows:
- `receipt-condition.ts:37` `lineConditionFields` is the precedent.
- Add `linePhotoFields`, used by the three review-row builders only (A3).

Routes:
- `src/api/receiving.controller.ts` — the DTO mapping (`lines: dto.lines.map` at `:133`) passes `photoRefs`. New routes:
  - `POST :tenantId/receiving/receipt-photos` (`DeviceSessionGuard`, **device credential + `x-op-operator`**, A7);
  - `GET …/goods-receipts/:grnId/photos`;
  - `POST …/goods-receipts/:grnId/lines/:lineId/photos`;
  - `POST …/goods-receipts/:grnId/photos/:attachmentId/remove`.
- `assertUuidParam` union `:599` widens (A4).

`src/modules/inbound/receiving.dto.ts`:
- `photoRefs`;
- `photoCount`/`pendingPhotoCount` on the lines read (`receiving.facade.ts:486`);
- `photoCount` on GRN list rows;
- snapshot `receiptPhotos {enabled, maxPerLine, maxPerReceipt, maxBytes}` beside `receiptDamageReasons` (`receiving.dto.ts:1471`, facade `:753`).

New module, `src/modules/attachments/`:
- `attachments.module.ts`: the `FILE_STORE` provider via `fileStoreFromEnv`, exported. It imports no sibling module.
- `file-store.ts`: port `{mode, put, presignGet({key, contentType, filename}) → {url, expiresAt}, delete}`, plus `none` and S3 (`local` = endpoint + path-style + public endpoint, A21).
- `image-sanitize.ts`: pure allow-lists (A12).
- `upload-gate.ts`: the semaphore (A16).
- `attachment-records.ts`: the free-function seam (imports only `drizzle-orm` + `shared/`, guide §7h), with the advisory ref lock (A1) and `onConflictDoNothing({target, where})` (A6):
  - `reserveUploadInTx`
  - `finalizeDeviceUploadInTx` (A2's table)
  - `finalizeOwnedUploadInTx`
  - `claimRefsInTx`
  - `listByParentInTx` (optional `clientId`)
  - `countLiveInTx`
  - `markRemovedInTx`
- `attachments.facade.ts`: `sweep(tenantId, now)` (A10).

Inbound commands and reads:
- `src/modules/inbound/receipt-photo.command.ts`: `uploadFromDevice`, `addOnWeb`, `remove`.
- `src/modules/inbound/portal-inbound.ts` + `inbound.facade.ts`: A4.
- `src/api/portal.controller.ts`: the two receipt routes; `assertUuidParam` `:555`.

Elsewhere:
- `src/modules/tenancy/permissions.ts`: `receipt.attach`, `receipt.photo-remove`.
- `src/modules/tenancy/sync-report.command.ts`: `'receipt-photo.stage'` in `RejectedOpType`, `REJECTED_OP_TYPES`, `REJECTED_OP_DECISIONS_BY_TYPE` (`:174`, `['discard']`) and `PAYLOAD_FIELDS` (`:335`, A19).
- `src/shared/primitives/audit.ts`: `attachment` in `AUDIT_TARGET_TYPES` (`:44`), and A25's actions in `AUDIT_NEW_ACTIONS` (`:142`).
- `src/jobs/jobs.module.ts`: `AttachmentSweepWorker`, modelled on `AuditExportWorker` (`:1350-1414`, A11; A22 when 6-2c has landed).
- `.env.example` (the model is `:160-178`): `FILE_STORE`, `ATTACHMENTS_S3_BUCKET`, `FILE_STORE_S3_ENDPOINT`, `FILE_STORE_PUBLIC_ENDPOINT`, `ATTACHMENT_URL_TTL_SECONDS`, `ATTACHMENT_PURGE_DAYS`, `ATTACHMENT_SWEEP_POLL_MS`, `FILE_STORE_MINIO_TEST_ENDPOINT`.
- `docker-compose.yml`: pinned `minio` plus a bucket-init one-shot.
- CI: the `minio-integration` job.

Migration:
- `drizzle/NNNN_attachments.sql` + journal + snapshot + `schema.ts`.
- Models: probes `0086_gate_ins.sql:24-32,177-419`; RLS `0084_licences.sql:106-121`.

**Web** (`workspace/core/frontend/wms-fe`, Next 16; no CSP today):
- `src/components/inbound/inbound-cards.tsx`: `GoodsReceiptLinesPanel` (`:639-668`) gets a per-line count that opens the dialog; `GoodsReceiptsCard` (`:459`) gets a row indicator.
- New `src/components/inbound/receipt-photos.tsx`:
  - grid and lightbox;
  - awaited/expired/removed placeholders;
  - Add (`receipt.attach`);
  - Remove/Cancel with reason (`receipt.photo-remove`);
  - the deduped refetch (A28).
- New `src/lib/receipt-photos.ts`: `prepareImageForUpload` (refuses > 10 MB, undecodable, HEIC with A28's words) and the status words.
- New `src/lib/use-receipt-photos.ts`.
- `src/lib/api/client.ts`: wrappers (multipart as `fetchApiImportCatalog` `:1029-1049`).
- `src/components/portal/portal-inbound.tsx`: `ReceiptsSection` beside `AsnsSection` (`:79`) and `PurchaseOrdersSection` (`:325`), including the removed placeholder.
- New `src/lib/use-portal-receipts.ts`. The portal boundary test must pass.
- `src/lib/users.ts:15,282`: the capabilities.
- `src/lib/audit.ts`: the `attachment` label.
- The review-queue label for `receipt-photo.stage`.
- Regenerate the client.

**Handheld** (`workspace/core/mobile/wms-mobile`, Expo 57):
- **Deps:** `expo-image-manipulator` (a native module: **the only addition that forces a new dev/EAS build**) and `expo-file-system`, through `expo-file-system/legacy` for the directory APIs (`moveAsync`, `deleteAsync`, `readDirectoryAsync`, `getFreeDiskStorageAsync`). `expo-file-system` already ships inside `expo`.
- **Capture:** `CameraView.takePictureAsync` (`src/scanning/adapters.tsx:2,99`).
- **`src/offline/crypto.ts`:** new `sealBytesWithKey(bytes, key)` and `openWithKeyBytes` (exists, `:42`). The envelope stays `v1:<iv>:<tag>:<ct>` in base64: about **+33 %** over the JPEG, plus 28 bytes and the prefix.
- **New `src/attachments/photo-store.ts`:**
  - seal (`.sealed.tmp` → rename), open to bytes, delete;
  - temp-dir wipe;
  - orphan sweep keeping queued and retained refs (A19);
  - quota, counting draft photos too (B8: ≥ 200 queued + draft, or < 200 MB free → capture refused).
- New `src/components/photo-capture.tsx`, with the A26 hint.
- **`app/receive.tsx`:**
  - the per-line Photo button when `snapshot.receiptPhotos?.enabled`;
  - the damaged-line hint;
  - deleting a line or photo deletes its file;
  - Confirm (`:605-618`) builds the receipt op and the photo ops and calls `enqueueOps` (A8).
- **`src/receiving/draft.ts`:** `photoRefs` per line; caps in `canConfirm` `:385` / `confirmBlocker` / `confirmPayload` `:2044` (A5).
- `src/offline/types.ts:48-59`: the `OpType`.
- `src/offline/outbox-store.ts` + `store.ts`: `enqueueOps`.
- **`src/offline/engine.ts`:** the photo lane (A24) and the operator-changed exemption (`:123-133`, A7).
- **`src/api.ts`:** `uploadReceiptPhoto` — a hand-built multipart `Uint8Array`, the device token, `x-op-operator`, a 60 s timeout. It does not reuse `request()` (`:92-127`, which forces JSON with a 10 s timeout).
- **`src/state/op-dispatch.ts`:** open the sealed file into memory and send.
- **`src/state/replay-classification.ts`:** the photo arm.
  - unreachable: `file-storage-failed`, `file-storage-busy`, `attachment-staging-limit`, 409 `conflict`, timeouts;
  - unreachable while < 7 d, then rejected: `file-storage-unavailable`;
  - shared arms: `device-revoked`;
  - rejected: `attachment-*` (incl. `-ref-conflict`), `validation-failed`, `role-denied` and the rest;
  - rejected locally: a missing file → `photo-file-missing`.
- **`src/state/device-store.ts`:** init temp wipe + orphan sweep; reset deletes the photo and temp dirs before the key (Gotcha 15); the file lifecycle hooks (A19).

## Tasks & Acceptance

**Execution:**
- [ ] BE: the migration + schema; the attachments module (port, adapters, allow-list sanitizer, semaphore, seam, sweep facade); `receipt-photo.command.ts`; the `grn.submit` hash/normalise/claim plus the three review builders; routes, DTOs, portal facade reads; capabilities, audit vocabulary, sync-report type and `PAYLOAD_FIELDS`; the worker; `.env.example`; compose MinIO; the `minio-integration` CI job; OpenAPI.
- [ ] BE tests:
  - `test/image-sanitize.spec.ts`: every A12 arm with real fixtures (progressive + APP13 between scans, MPF, JFXX, GPS EXIF, PNG text, APNG, WebP EXIF, animated WebP, polyglot tail, SVG/HEIC/GIF, truncated, 8,001 px).
  - Adapter (`aws-sdk-client-mock`): put headers; presign `response-content-disposition`/`-content-type`/expiry = the min; `fromEnv` failures, incl. `local` + production.
  - `test/file-store-minio.spec.ts` (A14).
  - `test/receipt-photos.spec.ts`:
    - every matrix row;
    - both binding orders as parked-waiter races (A1);
    - the A2 table, row by row;
    - Apply re-binding for the three Apply-capable rows;
    - the device-scope skip (A17);
    - the operator-credential path (A7);
    - caps;
    - semaphore and staging 503/429;
    - a same-key two-request sequence on web add (`raceTwice` + `waitParked` on the line lock);
    - `expectAuditRow` for every keyed action, incl. after a replay.
  - A new `grn.submit` golden; the old goldens unchanged.
  - `wms_rls_probe`: the tenant arm and the client arm (A27).
  - The portal two-layer scan; a foreign-id 404; the removed placeholder.
  - Sweep: each arm, the referenced-ref keep (A10, with `EXPLAIN`), sweep vs final tx, two sweepers.
  - The OpenAPI path list.
- [ ] Web: the photos dialog, the GRN indicators, the portal Receipts section, the capability mirror, client regen, tests (states, gating, add/remove/cancel, deduped refetch, HEIC message).
- [ ] Handheld: deps; `sealBytesWithKey`; the photo store; capture UI; draft refs + caps; `enqueueOps`; the photo lane; the operator exemption; dispatch; classification (every arm pinned); quota; temp/orphan/reset cleanup.
  - Tests: atomic enqueue crash, plaintext after kill, storage-down lane, a capturer badged out, a typed-array body against the dev server.
- [ ] Meta docs (after code):
  - a new `docs/design/modules/attachments.md` (both binding orders as sequence diagrams, A2's table, the sweep);
  - `inbound.md`;
  - `SYSTEM-DESIGN.md` (modules, background work, where state lives);
  - `IMPLEMENTATION-GUIDE.md` §8 (reservation-then-put-then-finalize for a non-transactional write the caller waits on; the terminal-then-delete sweep);
  - `API-SURFACE.md`, `DEPLOY.md` §2;
  - mobile design (the photo lane, the operator exemption, sealed files) and FE design;
  - PENDING (worker audit A22, legal hold);
  - both repo READMEs.

**Acceptance Criteria:**
- **Dead-zone receipt (B23).** Given a dead-zone receipt with two damage photos on line 2, when the device syncs, then the GRN's response body, its ledger rows and its idempotency snapshot equal those of the same receipt without `photoRefs`, and both photos show on line 2 on the web and in the client's portal Receipts detail.
- **EXIF stripped (B23).** Given a JPEG with GPS EXIF uploaded from the web, when the `minio-integration` job fetches its presigned URL, then the bytes contain no APP1 and `Content-Type` is `image/jpeg`.
- **Migration.** Given the migration on a database at the previous head, when it runs, then every refused probe is refused by its named constraint, every accepted shape inserts and is rolled back, and `db:generate` reports no changes.
- **Authority and isolation.** Given an operator web session, removing a photo is 403 `role-denied`. Given a portal session of client A, client B's GRN or photo is 404.
- **Storage off.** Given `FILE_STORE=none`, the snapshot hides the Photo button and receipts work unchanged.
- **B1.** Given storage down with photo ops queued, when a later `grn.submit` is queued and the device syncs, then the receipt settles and the photo ops stay queued.
- **B2.** Given a kill during Confirm, then the outbox holds the receipt and all its photo ops, or none of them.
- **B3.** Given a kill at any capture step, then no decrypted photo exists outside the temp dir after the next init.
- **K7/B4.** Given the capturer badged out and another operator badged in, when the queue syncs, then the photos upload and are attributed to the capturer.
- **Portal removed.** Given a removed photo, the client's portal shows "Removed by the warehouse" with no image.
- **Staging cap.** Given 200 unbound staged photos from one device, the next upload is 429 `attachment-staging-limit`, and the device keeps it queued.
- **Sweep.** Given a `staged` ref named by an open review row, the sweep never discards it. Given two rows that once shared an object key, the sweep never deletes a live row's bytes.

## Design Notes

**Statuses:**

```
uploading ─device─► staged ─claim─► attached ─remove─► removed (purged_at after ATTACHMENT_PURGE_DAYS from removed_at)
uploading ─device, ref awaited|expired─► FILL that row → attached; reservation deleted first
claim, no ref row ─► awaited ─fill─► attached     awaited ─remove─► removed (no object)
awaited ─created_at + N d─► expired ─fill─► attached
uploading ─web─► attached (owner set at finalize)
uploading ─created_at + 1 h─► discarded ; staged ─created_at + N d─► discarded ; then delete → purged_at
```

**Upload protocol** (A18 order; the put is outside every transaction):

0. **Above the transaction:**
   1. key (400);
   2. file present (400);
   3. multer limits (A15);
   4. device: `x-op-operator` (400) and `capturedAt` as a Z instant (400); web remove: `reason` 1–200;
   5. `rawSha256`;
   6. hash. Device: `{tenantId, surface: 'device-photo', deviceId, opOperator, capturedAt, rawSha256}`. Web add: `{tenantId, surface: 'web-photo', grnId, grnLineId, rawSha256}`.
1. **Tx A:**
   1. authority (A7 | `receipt.attach`);
   2. replay;
   3. mode `none` → 503 `file-storage-unavailable`;
   4. web: GRN line in the GRN in the tenant (404);
   5. device: the staging cap (429);
   6. semaphore slot (503 `file-storage-busy`), held until the put returns;
   7. sanitize (415/422);
   8. `reserveUploadInTx`: an `uploading` row, owner null, no `client_ref`, `upload_key` = the key. On a conflict on `(tenant_id, upload_key) WHERE status='uploading'`, the existing row is reused if its `upload_hash` matches; otherwise 422.
2. **`FileStore.put`.** A failure is 503 `file-storage-failed`, and the reservation stays.
3. **Tx B:**
   1. authority;
   2. replay;
   3. lock the reservation (`discarded` or gone → 503 `file-storage-failed`);
   4. web: lock the GRN line `FOR UPDATE`, apply the caps (409), then finalize as `attached` (owner, the GRN's `client_id`, warehouse, `uploaded_at`);
   5. device: the advisory ref lock (A1), then A2's table;
   6. audit (A25);
   7. `idempotency_keys` last.

**Same key, two concurrent requests (K12):**
1. R1's Tx A inserts the reservation.
2. R2's Tx A conflicts, finds the same hash, and reuses it.
3. Both put the identical bytes to the same object key (an idempotent overwrite).
4. Whichever reaches Tx B first locks the reservation and finalizes. On the device fill path it deletes the reservation; otherwise the reservation **becomes** the row. It then writes the key and commits.
5. The other, parked on the lock or the advisory, wakes, and its replay re-serves the snapshot.

No orphan is left, and nothing is "swept" on this path.

**The claim** (A1, A17, A27):
- Inside `grn.submit`, immediately before the outbox append, take the advisory locks with refs sorted.
- Per ref, `INSERT … awaited (owner = line, owner_parent = GRN, client_id/warehouse_id from the GRN) … ON CONFLICT DO NOTHING` (A6). If nothing was inserted, lock the row:
  - `staged` with `device_id = command.deviceId` → `attached` + audit;
  - anything else → skipped + the `ref-skipped` audit and warn.

**Migration** — `drizzle/NNNN_attachments.sql`:
- NNNN is next free at code time. Main is at 0088; open work holds 0089–0091, and 4-2a/4-3a/3-3a take the next ones.
- A fail-fast `DO` comes first.

The table:

```sql
CREATE TABLE "attachments" (
  "id" uuid PRIMARY KEY, "tenant_id" uuid NOT NULL, "client_id" uuid, "warehouse_id" uuid,
  "purpose" text NOT NULL, "status" text NOT NULL, "source" text NOT NULL,
  "owner_type" text, "owner_id" uuid, "owner_parent_id" uuid,
  "client_ref" text, "upload_key" text, "upload_hash" text, "raw_sha256" text,
  "object_key" text, "content_type" text, "byte_size" integer, "sha256" text, "width" integer, "height" integer,
  "captured_at" timestamptz, "uploaded_at" timestamptz, "device_id" uuid, "created_by" uuid,
  "removed_by" uuid, "removed_at" timestamptz, "removed_reason" text, "purged_at" timestamptz,
  "created_at" timestamptz NOT NULL DEFAULT now(), "updated_at" timestamptz NOT NULL DEFAULT now());
```

CHECKs. Each is named; a nullable column always says `IS NULL OR …` / `IS NOT NULL AND …`.
- `attachments_purpose_check`: `purpose IN ('receipt-damage')`.
- `attachments_status_check`: `status IN ('uploading','staged','awaited','attached','removed','expired','discarded')`.
- `attachments_source_check`: `source IN ('handheld','web')`.
- `attachments_owner_type_check`: `owner_type IS NULL OR owner_type IN ('goods_receipt_line')`.
- `attachments_owner_together`: `num_nulls(owner_type, owner_id, owner_parent_id) IN (0, 3)`.
- `attachments_owned_statuses`: `status NOT IN ('awaited','attached','removed','expired') OR owner_id IS NOT NULL`.
- `attachments_unowned_statuses`: `status NOT IN ('uploading','staged') OR owner_id IS NULL`.
- `attachments_object_together`: `num_nulls(object_key, content_type, byte_size, sha256, width, height) IN (0, 6)`.
- `attachments_object_required`: `status NOT IN ('uploading','staged','attached','discarded') OR object_key IS NOT NULL`.
- `attachments_object_absent`: `status NOT IN ('awaited','expired') OR object_key IS NULL`. (`removed` may have either — a cancelled `awaited` has none.)
- `attachments_purged_status`: `purged_at IS NULL OR (status IN ('removed','discarded') AND object_key IS NOT NULL)`.
- `attachments_content_type_check`: `content_type IS NULL OR content_type IN ('image/jpeg','image/png','image/webp')`.
- `attachments_size_check`: `byte_size IS NULL OR byte_size BETWEEN 1 AND 10485760`.
- `attachments_dims_check`: `(width IS NULL OR width BETWEEN 1 AND 8000) AND (height IS NULL OR height BETWEEN 1 AND 8000)`.
- `attachments_sha_check`: `(sha256 IS NULL OR sha256 ~ '^[0-9a-f]{64}$') AND (raw_sha256 IS NULL OR raw_sha256 ~ '^[0-9a-f]{64}$')`.
- `attachments_client_ref_check`: `client_ref IS NULL OR client_ref ~ '^[0-9A-HJKMNP-TV-Z]{26}$'`.
- `attachments_ref_statuses`: `status NOT IN ('staged','awaited') OR client_ref IS NOT NULL`.
- `attachments_uploading_no_ref`: `status <> 'uploading' OR client_ref IS NULL`.
- `attachments_handheld_device`: `source <> 'handheld' OR device_id IS NOT NULL`.
- `attachments_upload_pairing`: `status <> 'uploading' OR (upload_key IS NOT NULL AND upload_hash IS NOT NULL AND raw_sha256 IS NOT NULL)`.
- `attachments_removed_pairing`: `(status = 'removed' AND removed_by IS NOT NULL AND removed_at IS NOT NULL AND removed_reason IS NOT NULL AND char_length(removed_reason) BETWEEN 1 AND 200) OR (status <> 'removed' AND removed_by IS NULL AND removed_at IS NULL AND removed_reason IS NULL)`.

Indexes, all `CREATE [UNIQUE] INDEX IF NOT EXISTS`, outside any `DO` block (no word INDEX inside one):
- `attachments_tenant_client_ref_unique` `(tenant_id, client_ref) WHERE client_ref IS NOT NULL`
- `attachments_tenant_upload_key_unique` `(tenant_id, upload_key) WHERE status = 'uploading'`
- `attachments_tenant_object_key_unique` `(tenant_id, object_key) WHERE object_key IS NOT NULL AND purged_at IS NULL`
- `attachments_tenant_parent_idx` `(tenant_id, owner_parent_id, owner_id) WHERE owner_parent_id IS NOT NULL`
- `attachments_tenant_device_staged_idx` `(tenant_id, device_id) WHERE status = 'staged'`
- `attachments_tenant_sweep_idx` `(tenant_id, status, created_at) WHERE status IN ('uploading','staged','awaited') OR (status IN ('removed','discarded') AND purged_at IS NULL)`
- `attachments_sweep_discovery_idx` `(status, created_at)`

RLS:
- `ENABLE ROW LEVEL SECURITY`.
- `attachments_tenant_isolation` in the 0084 shape (the tenant arm AND (`app.client_id` unset OR `client_id` = the stamp)), on USING and WITH CHECK.

Probes and proof:
- The post-migration `DO` runs accepted shapes, rolled back by the sentinel `P<NNNN>`: `uploading` device, `uploading` web, `staged`, `awaited`, `expired`, `attached` (handheld and web), a `removed` with an object and one without, `discarded` + `purged_at`.
- One refused insert per named CHECK, each asserted by its constraint name.
- It is a new table, so there is no large-table lock. No FKs.
- `db:generate` must report "No schema changes".

**Personal data (DPDP, B15).**
- Purpose: evidence of receipt condition, shared with the owning client.
- Faces, number plates and drivers can appear incidentally. The capture hint discourages it; there is no automated blurring.
- Access: tenant staff, and the owning client's portal users (attached photos only).
- Retention: as long as the GRN.
- Erasure: soft removal, then the bytes are purged after `ATTACHMENT_PURGE_DAYS`, with a ≤ 300 s URL tail.
- An urgent purge, operator self-removal and legal hold are deferred.

**Infra interface — what 6-2d (or a 6-2b amendment) must add.** None of this exists on `origin/feat/6-2b-aws-infra`: only the ledger-anchors and ALB-logs buckets, an API task role with no policy (`infra/modules/environment/iam.tf:5-7`), and no CORS.

Bucket `${local.name}-attachments-${random_id.attachments.hex}`:
- the name is a random suffix, not the account id;
- in ap-south-1;
- `BucketOwnerEnforced`;
- all public access blocked;
- SSE-S3;
- `DenyNonTls`;
- **no `aws:SourceVpce` condition** (browsers download directly);
- **versioning off**;
- lifecycle: only abort incomplete multipart uploads after 1 day;
- **no CORS rule**;
- production **not** `force_destroy`; staging `force_destroy`.

IAM:
- API task role: `s3:PutObject` and `s3:GetObject` on `arn:aws:s3:::<bucket>/tenants/*` only.
- Worker task role: `s3:DeleteObject` on the same prefix.
- If an S3 gateway endpoint carries a policy, it must allow the attachments bucket.

Environment:
- api + worker: `FILE_STORE=s3`, `ATTACHMENTS_S3_BUCKET`, `AWS_REGION`, `ATTACHMENT_PURGE_DAYS`.
- api: `ATTACHMENT_URL_TTL_SECONDS=300`.
- worker (`worker_job_settings`): `ATTACHMENT_SWEEP_POLL_MS=600000`.

Monitoring: CloudWatch alarms on `BucketSizeBytes` and on a request-count spike.

Memory: about 4 × 20 MB inside the semaphore (raw + sanitized), plus multer buffering of concurrent uploads in flight (≤ 10 MB each). Size the API task with ≥ 512 MB headroom over today's.

Runtime and edge:
- No writable path is needed under 6-2c.
- No ALB change.
- A future web CSP must admit the bucket host in `img-src`.

## Verification

**Commands:**
- `cd workspace/core/backend/wms-be && bun run lint && bun run typecheck && bun run test && bun run build` — expected: all pass. Run one jest invocation at a time.
- `cd workspace/core/backend/wms-be && bun run db:migrate && bun run db:verify && bun run db:generate && git status --short` — expected: "No schema changes", no untracked files.
- `cd workspace/core/backend/wms-be && docker compose up -d minio && FILE_STORE_MINIO_TEST_ENDPOINT=http://localhost:9000 bun run test -- test/file-store-minio.spec.ts` — expected: pass. This is also the `minio-integration` CI job.
- `cd workspace/core/frontend/wms-fe && bun run test && bun run lint && bun run typecheck && bun run build && bun run check:capability-mirror` — expected: pass. The generated-client job stays red until the BE merges.
- `cd workspace/core/mobile/wms-mobile && bun test && bunx tsc --noEmit` — expected: pass.

**Manual checks:**
- On a dev build with `FILE_STORE=local`: take two photos on a damaged line with the simulated offline switch on, badge out, and badge in as the same operator. Sync. Both photos appear on the web and in the portal, and `exiftool` shows no GPS.
- Stop MinIO and queue another receipt. It still syncs.

## Implementation Notes

## Spec Change Log

## Review Triage Log

Design review, 2026-10-23 (D). Two layers: a claims check against origin/main (K) and a blind reviewer (B). The finding text is condensed from the review hand-off. Every resolution is recommended and taken autonomously.

| ID | Verdict | Finding → resolution |
|---|---|---|
| K1 | high | The ref read in the upload and in the claim races; a reservation carrying `client_ref` collides. → A1 |
| K2 | high | A late upload after `expired` is lost; `attached`/`removed` meetings are unspecified; a rejected receipt's refs are unreachable. → A2 |
| K3 | medium | `clientRefusalLines`/`RejectedGrnLineDto` are the wrong carry; `grn.lines-refused` is Discard-only. → A3 |
| K4 | medium | The portal read placement does not match `PORTAL_READS` (facade-keyed); the `assertUuidParam` unions are closed. → A4 |
| K5 | medium | The device cannot see the per-receipt cap. → A5 |
| K6 | medium | A plain `ON CONFLICT` cannot target a partial unique index. → A6 |
| K7 | high | Photo ops die under the operator-changed hold or a 409 `operator-mismatch` after a badge-out. → A7 |
| K8 | high | The two-step enqueue can strand refs or photos on a crash. → A8 |
| K9 | high | Plaintext camera/manipulator/temp files survive on disk. → A9 |
| K10 | low | No byte-seal API; the file-system API surface; rebuild scope. → Code Map (`sealBytesWithKey`, `/legacy`, only the manipulator rebuilds) |
| K11 | high | The sweep can discard a staged ref an open review row still names. → A10 |
| K12 | high | Sweep atomicity, object reuse, `updated_at`, named ages; "its reservation is swept" was wrong. → A10, the Design Notes sequence |
| K13 | high | A drop-list sanitizer admits unknown segments and chunks (MPF, animation, between-scan APPn). → A12 |
| K14 | medium | Filename injection, the signed type, URL lifetime vs credentials, URLs in snapshots, the bucket name, no real-S3 proof. → A14 |
| K15 | low | Request order and multer limits unspecified. → A15 |
| K16 | medium | Unbounded concurrent buffering; unbounded staging per device. → A16 |
| K17 | medium | The claim binds any device's staged ref; "128-bit" is wrong. → A17 |
| K18 | medium | Sanitizing before the replay lets a later sanitizer refuse a committed op. → A18 |
| K19 | medium | No `PAYLOAD_FIELDS` entry, no photo op payload, no file lifecycle. → A19 |
| K20 | medium | Owner on `uploading`; missing accepted probes; the CHECK arms not separately named. → A13, Design Notes |
| K21 | medium | `awaited` cannot be cancelled; the cap definition. → A13, A20. **Cap applied as `attached` + `awaited`, not "+ staged"**: a staged row has no line yet, so it cannot count toward a line |
| K22 | low | The remove fingerprint unspecified. → A20 |
| K23 | low | Local-mode credentials and the presign host inside docker; the production profile. → A21 |
| K24 | low | 6-2c's worker health; two-instance safety. → A22 |
| K25 | low | Capability naming. → A20 (`receipt.photo-remove`) |
| K26 | low | The photos list is unbounded. → A23 |
| B1 | high | A stuck photo blocks every later op in FIFO. → A24 |
| B2 | high | Non-atomic enqueue. → A8 |
| B3 | high | Plaintext on disk. → A9 |
| B4 | high | The operator change at replay. → A7 |
| B5 | medium | Storage-off rejects photos permanently. → A19 |
| B6 | medium | Late arrival after expiry. → A2 |
| B7 | high | Referenced staged refs swept. → A10 |
| B8 | low | Torn seal writes; draft photos outside the quota. → A9, Code Map |
| B9 | medium | The sweep deletes before committing a terminal state. → A10 |
| B10 | medium | Shared `object_key` deletion. → A10 (unique live key) |
| B11 | low | Ages on `updated_at` drift. → A10 |
| B12 | medium | Cross-tenant discovery unspecified. → A11 |
| B13 | low | Audit gaps (claim, fill, purge). → A25 |
| B14 | medium | The fixed purge delay; the portal silent on removal; legal hold. → A10, A4; legal hold deferred |
| B15 | medium | Personal data in photos. → A26, Design Notes; urgent purge and self-removal deferred |
| B16 | high | Animation and multi-frame content. → A12 |
| B17 | medium | The `awaited` client/warehouse; staff view of removed photos; the URL tail; cross-client list proof. → A27, A20 |
| B18 | medium | Memory pressure. → A16, infra interface |
| B19 | medium | Disposition filename. → A14 |
| B20 | medium | Infra gaps (VPCE pin, endpoint policy, prefix, alarms, `force_destroy`). → infra interface |
| B21 | low | Cancelling an awaited placeholder. → A13, A20 |
| B22 | low | A silent skip of a stale ref. → A25 |
| B23 | medium | Vague and missing ACs. → Acceptance Criteria |
| B24 | low | Device clock, refetch storms, HEIC message. → A28 |
