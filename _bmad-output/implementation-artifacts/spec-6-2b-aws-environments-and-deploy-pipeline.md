---
title: '6-2b AWS environments and deploy pipeline — staging and production in ap-south-1 as Terraform, a GitHub Actions deploy (build → ECR → migrate → roll) that does nothing until configured'
type: 'feature'
created: '2026-10-22'
baseline_commit: 'f23986de491c1d220df6e2959855602a5ce529ec'  # WMS-Meta (infra/ + .github/workflows); wms-be/wms-fe/wms-mobile: unchanged
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
context:
  - 'docs/initiatives/production-readiness.md'
  - 'docs/design/SYSTEM-DESIGN.md'
  - 'docs/design/IMPLEMENTATION-GUIDE.md'
  - 'docs/design/PENDING.md'
  - 'docs/design/DEPLOY.md'
  - '_bmad-output/implementation-artifacts/spec-6-2a-container-images-and-safe-migrations.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** 6-2a ships images, a guarded migrator and a runbook (`docs/design/DEPLOY.md`), but there is nowhere to run them. The roadmap's ★ 6.2 needs staging and production environments in AWS Mumbai (D6), a secrets manager and a deploy pipeline. No IaC exists in any repo.

**Approach:** Terraform in a new meta-repo `infra/`, with one `environment` module instantiated twice (staging and production), plus a `global` stack (ECR, the GitHub OIDC provider, deploy roles) and a `bootstrap` stack (the state bucket). A meta-repo GitHub Actions `deploy.yml`, run by `workflow_dispatch`, builds both images at chosen refs, pushes them to ECR by SHA, runs the one-shot migrate task, then rolls api → worker (stop-then-start) → web. It no-ops when the environment's deploy role is not configured. Meta-only: no wms-be or wms-fe change and no DB migration. Decisions are recommended, taken autonomously (memory: autonomous loop).

**Decisions (recommended, taken autonomously):**
1. **Tooling.** Terraform `>= 1.10, < 2.0`; provider `hashicorp/aws ~> 6.0` and `hashicorp/random ~> 3.6`. State lives in S3 with `use_lockfile = true` (no DynamoDB), one key per stack, and the backend is partially configured (`-backend-config`). Region `ap-south-1` everywhere.
2. **Layout:**
   - `infra/bootstrap`: local state. It creates the state bucket (versioned, SSE-KMS, public access blocked, TLS-only policy).
   - `infra/global`: ECR repos `wms-be` and `wms-fe` (immutable tags, scan on push, lifecycle keeps 100). The GitHub OIDC provider. One deploy role per environment, assumable only from `repo:chinnisasi/WMS-Meta:environment:<env>`.
   - `infra/modules/environment`: everything per environment.
   - `infra/envs/{staging,production}`: thin roots holding sizes and flags.
   - One image per SHA is promoted staging → production, never rebuilt.
3. **Network:**
   - A VPC across 2 AZs (`ap-south-1a`/`1b`), with public (ALB, NAT), private-app (ECS) and private-data (RDS, Valkey) subnets.
   - NAT: one gateway in staging, one per AZ in production. Outbound is needed for Expo push, channel APIs and e-way.
   - Security groups chain ALB → app → data; data accepts only from the app SG.
4. **Edge:**
   - One ALB per environment with host routing: `app.<domain>` → web target group (3001), `api.<domain>` → API target group (3000). HTTP redirects to HTTPS; the ACM cert is DNS-validated in a caller-supplied Route 53 zone (`route53_zone_id`, `domain`).
   - Staging uses `app.staging.<domain>` / `api.staging.<domain>`. Both hosts share one registrable domain (the cookie rule; never `*.elb.amazonaws.com`).
   - ALB `idle_timeout` 60.
   - API target group: health `/api/v1/health/ready` (interval 10 s, timeout 5 s, healthy 2, unhealthy 3, matcher 200), deregistration delay 25 s. All-unhealthy routing stays fail-open (the ALB default), which DEPLOY.md's shared-dependency readiness relies on.
   - Web target group: health `/runtime-config.js`, deregistration delay 25 s.
5. **ECS Fargate (X86_64, matching the CI-verified images), one cluster per environment:**
   - **api:** staging 1 task, production 2, autoscaling on CPU 60% up to 6. Production needs ≥ 2 for a rolling deploy with no gap.
   - **worker:** exactly 1, deployment minimum healthy 0% / maximum 100% (stop-then-start, DEPLOY.md). It is not attached to the ALB.
   - **web:** staging 1, production 2.
   - All three: `stopTimeout` 30, deployment circuit breaker with rollback, Container Insights on.
   - **migrate:** a task definition only (no service). Command `["sh","-c","bun run db:migrate:deploy && bun run db:provision-roles"]`, with the owner URL.
   - Sizes are variables. Defaults: api 1 vCPU / 2 GB in production and 0.5 / 1 GB in staging; worker, web and migrate 0.5 / 1 GB.
   - Terraform owns task definitions with an `image_tag` variable and services `ignore_changes = [task_definition, desired_count]`. The pipeline registers revisions; Terraform creates the shape.
6. **Data:**
   - **RDS Postgres:** major 18 (matches compose), gp3 50 GB autoscaling to 500, encrypted. Parameter group sets `rds.force_ssl = 1`.
     - Production: Multi-AZ, `db.t4g.medium`, deletion protection, final snapshot, backups 14 days.
     - Staging: single-AZ, `db.t4g.small`, backups 7 days.
   - **ElastiCache Valkey** replication group (engine `valkey`, major 8), transit encryption on, AUTH token.
     - Production: 2 nodes, Multi-AZ automatic failover, `cache.t4g.small`.
     - Staging: 1 node, `cache.t4g.micro`.
   - Engine minors are variables; the implementer records them as "verify at the first `plan`" because AWS cannot be reached here.
7. **Secrets:**
   - **Terraform-generated** (`random_password`, 40 characters, alphanumeric so URLs need no escaping), stored in Secrets Manager under `wms/<env>/…`:
     - the RDS master password; `wms_app` and `wms_auth` passwords; the Valkey AUTH token;
     - the derived `DATABASE_URL` (wms_app), `DATABASE_AUTH_URL` (wms_auth), `MIGRATE_DATABASE_URL` (owner), and `VALKEY_URL` (`rediss://:token@primary:6379`).
     - DB URLs carry `?sslmode=require`; verify-full needs the RDS CA in the image (6-2c).
   - **Out-of-band:** Terraform creates `JWT_SECRET`, `MFA_ENCRYPTION_KEY`, `DEVICE_ENCRYPTION_KEY`, `CARRIER_ENCRYPTION_KEY`, `CHANNEL_ENCRYPTION_KEY` and `EMAIL_SEAL_KEY` as secrets with **no version**. The operator sets them (DEPLOY.md command), so they are never in state and a lost state never loses a key. A task cannot start until they exist (fail closed).
   - The state therefore holds the generated DB and Valkey credentials. Accepted: the state bucket is encrypted, versioned and readable only by the deploy roles.
   - Container wiring: api and worker get the app secrets plus `DATABASE_URL` / `DATABASE_AUTH_URL` / `VALKEY_URL`. Migrate gets `DATABASE_URL` = the owner URL, plus `WMS_APP_PASSWORD` / `WMS_AUTH_PASSWORD`. The 6-2a env split holds: `*_POLL_MS` on the worker only; `CORS_ORIGIN`, `TRUSTED_PROXY_HOPS=1` and `NODE_ENV=production` on the API.
8. **Other AWS:**
   - CloudWatch log groups per service (30 days staging, 90 production).
   - Production: an S3 ledger-anchor bucket (Object Lock COMPLIANCE, 2557-day default retention), worker role scoped to the code's actions, `LEDGER_ANCHOR_WORM=s3`. Staging: `LEDGER_ANCHOR_WORM=none` and no bucket, because COMPLIANCE objects cannot be deleted.
   - An SES v2 domain identity with Easy DKIM records in the zone, plus `ses:SendEmail` and `ses:GetSuppressedDestination` on the worker role, ready for 5-1a. `EMAIL_PROVIDER` stays `off` until 5-1a ships.
9. **Deploy pipeline** (`.github/workflows/deploy.yml` in the meta repo, `workflow_dispatch`):
   - Inputs: `environment` (staging | production), `be_ref`, `fe_ref` (default `main`), `dry_run_migrations` (bool).
   - Jobs use the GitHub environment of the same name, so production approval is a GitHub environment rule, documented and set outside this story.
   - **Gate:** when `vars.AWS_DEPLOY_ROLE_ARN` is empty, print "not configured" and succeed with every later job skipped.
   - **Build:** check out both repos at the refs and resolve SHAs. Skip any image whose SHA tag already exists in ECR (promotion), else build with buildx and push `:<sha>`.
   - **Migrate:** read `/wms/<env>/deploy` (an SSM JSON parameter Terraform writes: cluster, subnets, SG, family names) and register a migrate revision with the new BE image. `run-task`, wait, read the container exit code: 0 continues, 2 fails "migration refused — see DEPLOY.md §pre-build", anything else fails.
   - **Roll:** for each of api, worker, web, register a revision from the current one with only the image swapped, `update-service`, and `wait services-stable`.
   - Actions are pinned by commit SHA. Concurrency is one group per environment, never cancelled in flight.
   - `infra-ci.yml` (on PR and on push to main): `terraform fmt -check -recursive`, `init -backend=false` and `validate` for every root, and `actionlint`.
10. **Split → 6-2c, runtime hardening** (BE/FE code, after WMS-BE #124 and WMS-FE #109 merge). It covers:
    - BE `keepAliveTimeout` 65 s / `headersTimeout` 66 s, above the ALB's 60 s; **a go-live gate**: Node's 5 s default against the ALB's 60 s yields intermittent 502s;
    - a worker heartbeat (C31), as a Valkey key per job plus a health-only listener;
    - a bounded web drain with exit 0 (C30): Next 16 already waits on SIGTERM, but has no bound and exits 143, so DEPLOY.md's "exits without waiting" is corrected here;
    - the Bun in-image drain smoke (C26);
    - digest-pinned bases and the root-owned FE image with a writable cache (C19);
    - the RDS CA bundle and verify-full.

**Design-review amendments (A1–A16).** Where they differ from the decisions above, these override them. Recommended, taken autonomously.
- **A1 — Roll verification.**
  - After `update-service`, the pipeline polls `describe-services` in its own loop (bounded at 20 minutes) and never relies on `wait services-stable`.
  - Fail when the PRIMARY deployment's `rolloutState` is `FAILED`, or when its `taskDefinition` is not the ARN just registered. Success means `COMPLETED` on that ARN.
  - The job summary lists each service as rolled, failed or not attempted.
  - Mixed versions during a deploy (new api, old worker) are safe because migrations are additive (6-2a). A failed later roll leaves them mixed, and the fix is to re-run with `skip_migrations`.
- **A2 — Base revision and roles.**
  - Terraform writes each family's base task-definition ARN into the SSM `/wms/<env>/deploy` parameter.
  - The pipeline copies that revision, never "current" or "latest". It strips the read-only fields (`taskDefinitionArn`, `revision`, `status`, `requiresAttributes`, `compatibilities`, `registeredAt`, `registeredBy`), swaps only the image, and asserts that `taskRoleArn` and `executionRoleArn` equal the environment's own.
  - A Terraform shape change therefore reaches the next deploy, and a revision registered by another role is never inherited.
  - `iam:PassRole` is restricted to the environment's roles, with `iam:PassedToService = ecs-tasks.amazonaws.com`.
  - Unscopable actions (`ecs:RegisterTaskDefinition`, `ecs:DescribeTaskDefinition`, `ecr:GetAuthorizationToken`, `ses:GetSuppressedDestination`) use `Resource: "*"`, and say so in a comment. `UpdateService` and `RunTask` carry `ecs:cluster` conditions; `RunTask` is limited to the migrate family. The deploy role also gets `DescribeServices`, `DescribeTasks` and ECR `DescribeImages`.
- **A3 — Promotion is enforced.**
  - Staging builds and pushes with the staging role. ECR push belongs to that role alone; the production role can only pull and describe.
  - On success, a staging deploy writes `/wms/staging/deployed` = `{be, fe}` SHAs.
  - Production requires full 40-character SHAs, never builds, and fails unless both images exist in ECR **and** match `/wms/staging/deployed`.
  - Both GitHub environments are restricted to the `main` deployment branch (documented), and every job's `if:` also requires `github.ref == 'refs/heads/main'`.
  - The OIDC trust checks both `aud = sts.amazonaws.com` and `sub = repo:chinnisasi/WMS-Meta:environment:<env>`.
- **A4 — Variables and approvals.**
  - Repo-level `vars.AWS_DEPLOY_ROLE_ARN_STAGING` / `_PRODUCTION` are read by a gate job that declares **no** environment, so an unconfigured run needs no approval.
  - Migrate and roll are one `deploy` job under `environment: <env>`, so there is one approval and no gap between migrate and roll.
  - Build is its own job under `environment: staging`.
  - A global `wms-build` concurrency group serialises builds, and `ImageTagAlreadyExistsException` counts as success. Each environment's deploy job has its own concurrency group, never cancelled. DEPLOY.md documents that GitHub keeps only the newest pending run.
- **A5 — The per-role env table replaces "container wiring".** The implementer writes this table into DEPLOY.md §AWS, and the acceptance criteria check it.
  - **api:** `NODE_ENV=production`, `PORT=3000`, `TRUSTED_PROXY_HOPS=1`, `CORS_ORIGIN=https://app.<domain>`, `AWS_REGION`, `LEDGER_ANCHOR_WORM`, plus `LEDGER_ANCHOR_S3_BUCKET` and `LEDGER_ANCHOR_RETENTION_DAYS`. The API reports the WORM mode (`ledger-integrity.ts:819`); DEPLOY.md:96's "W only" is wrong and gets fixed. Also `EWAY_GATEWAY` and `CHANNEL_HTTP_TIMEOUT_MS` (defaults from the code). Secrets: `DATABASE_URL`, `DATABASE_AUTH_URL`, `VALKEY_URL`, `JWT_SECRET`, and the four encryption keys.
  - **worker:** the same as api minus `CORS_ORIGIN` and `TRUSTED_PROXY_HOPS`, plus every `*_POLL_MS` and per-tick setting from compose, `PUSH_GATEWAY` and `PUSH_HTTP_TIMEOUT_MS`.
    - `push_gateway` is a tfvar defaulting to the code's non-sending mode.
    - `EXPO_ACCESS_TOKEN` is an out-of-band secret wired only when `push_gateway = "expo"`.
  - **migrate:** `NODE_ENV=production`, the `MIGRATE_*` settings, and the secrets: the owner `DATABASE_URL`, `WMS_APP_PASSWORD`, `WMS_AUTH_PASSWORD`.
  - **web:** `PORT=3001`, `HOSTNAME=0.0.0.0`, `WMS_API_BASE_URL=https://api.<domain>/api/v1`. `WMS_API_INTERNAL_BASE_URL` is left unset, so server-side calls take the public ALB through NAT; that is accepted and recorded.
  - **Not wired:**
    - `MFA_ENCRYPTION_KEY_PREVIOUS`: a rotation step in DEPLOY.md adds it.
    - `EMAIL_*`: 5-1a wires `EMAIL_SEAL_KEY` on A+W and `WEB_BASE_URL`; recorded for 5-1a. Its secret container is created with no version and is not referenced, so nothing blocks task start.
- **A6 — Verify RDS privileges at the first staging deploy.** Before the first migrate, DEPLOY.md requires two checks as the master user:
  - `select rolbypassrls from pg_roles where rolname = current_user`
  - `select pg_has_role(current_user,'pg_read_all_stats','USAGE WITH ADMIN OPTION')`

  If either is false, `provision-roles` cannot run. That is a recorded go-live blocker with an investigation entry in PENDING (no fallback is invented here).
- **A7 — Health checks.**
  - The API target group's health check becomes liveness `/api/v1/health`. Health on `/ready` would let ECS kill and recycle every API task during a shared-dependency outage.
  - Readiness becomes a **deploy gate**: after the api roll, the pipeline polls `https://api.<domain>/api/v1/health/ready` until 200, bounded at 5 minutes, before rolling the worker. DEPLOY.md's readiness section is rewritten to match.
  - Each container gets an ECS `healthCheck`, since Fargate ignores the Dockerfile `HEALTHCHECK`: api and worker use `bun -e fetch` on `/api/v1/health`, and web uses `node -e fetch` on `/runtime-config.js`, each with a 30 s `startPeriod`.
  - The API service gets `health_check_grace_period_seconds` 60, and both target groups use matcher `200`.
- **A8 — Migrate mechanics.**
  - Run `run-task`, then check `failures[]`.
  - Poll `describe-tasks` in a loop bounded at 45 minutes, with job `timeout-minutes: 60`.
  - The exit code is the `migrate` container's `exitCode`. When it is absent (`TaskFailedToStart`), fail and print `stoppedReason`.
  - New inputs:
    - `skip_migrations` (rollback);
    - `dry_run_migrations`, which overrides the command to `bun run db:migrate:deploy --dry-run` with no provisioning;
    - `allow_locking`, validated against `^[A-Za-z0-9_,-]*$` and passed as `--allow-locking=<v>` only when non-empty.
  - Afterwards the pipeline prints the migrate log stream. It must never print task definitions or environment variables, and the repos are public.
- **A9 — Secret boundary.**
  - A separate **migrate execution role** alone can read the owner URL and the role passwords. The app execution role reads only the app secrets.
  - The deploy role reads only the migrate log group.
  - DEPLOY.md notes that the repos and workflow logs are public, so tfvars hold no account-sensitive values beyond the account ID.
- **A10 — State access.**
  - Terraform runs only from an operator (admin SSO) principal; the deploy roles get no state access.
  - The state bucket and KMS key policies allow only the operator principal and deny non-TLS access.
  - The generated credentials in state are an accepted risk. Moving them to write-only attributes (`password_wo`, TF ≥ 1.11) goes to PENDING.
  - The bootstrap state is migrated into the bucket after creation (README), and the bucket has `prevent_destroy`.
- **A11 — Accounts and stack ordering.**
  - One AWS account for both environments; separate accounts are recorded for 6.4.
  - The deploy roles move into the environment module, so their ARNs are local.
  - `global` holds the ECR repos, the OIDC provider and a shared SES identity for `<domain>`: Easy DKIM, a custom MAIL FROM `mail.<domain>` with its MX and SPF records, and a DMARC `p=none` TXT record.
- **A12 — ECR.** Lifecycle expires only untagged images after 7 days. Tagged images are kept, because they are rollback targets and the images production runs.
- **A13 — First apply.**
  - Services are created at `desired_count = 0`, and task definitions have `skip_destroy = true`.
  - The SSM parameter carries each service's target count.
  - When the current count is 0, the pipeline's first roll sets `--desired-count` to the target (api/web from tfvars, worker 1).
  - DEPLOY.md order: bootstrap → global → env apply → set the out-of-band secrets (from `file://` or stdin, never argv) → run the A6 checks → staging pipeline.
- **A14 — Data and edge details.**
  - **Valkey:** a parameter group with `maxmemory-policy noeviction`; at-rest encryption; snapshots kept 1 day in staging and 7 in production.
  - **Maintenance windows:** RDS and Valkey maintenance on Sunday 21:30–22:30 UTC (03:00 IST); RDS backups 20:00–21:00 UTC.
  - **RDS:**
    - minor-version upgrades automatic; Performance Insights at 7 days; the AWS-managed KMS key;
    - staging has `skip_final_snapshot`, production a named final snapshot;
    - `rds.force_ssl` is kept, although it is already the default.
  - **ALB:** TLS policy `ELBSecurityPolicy-TLS13-1-2-2021-06`; production gets deletion protection and access logs to an S3 bucket.
  - **Endpoints:** an S3 gateway endpoint in both environments. Production adds interface endpoints for ECR api/dkr, Secrets Manager and Logs.
  - **Secrets:** recovery window 0 in staging, 7 days in production.
  - **Burstable instances:** production `t4g` runs in unlimited-credit mode, so the CPU-credit alarm goes to 6.3.
  - **API count:** ≥ 2 in production is for AZ redundancy. It autoscales from 2 to 6; staging has no autoscaling.
- **A15 — Ledger anchors.**
  - Staging also gets the bucket: `LEDGER_ANCHOR_WORM=s3`, `LEDGER_ANCHOR_RETENTION_DAYS=1`, and a 1-day default retention, so the S3 path runs before production.
  - Production keeps 2557 days.
  - Both use SSE-S3 and the code's actions: `PutObject` and `PutObjectRetention`, `GetObject` and `GetObjectVersion` on `ledger-anchors/*`, and `ListBucket` on the bucket.
- **A16 — Housekeeping.**
  - Lock files are generated for `linux_amd64` and `darwin_arm64`.
  - Rotating the generated passwords: `apply` updates the secrets, then the next pipeline's `provision-roles` changes the DB passwords and the roll picks them up. Between those two steps, new app connections fail, so rotate during low traffic (documented).
  - The 6-2c keep-alive gate is re-worded as "verify under Bun (the BE runs `bun src/main.ts`)"; staging may show intermittent 502s until 6-2c lands.
  - Implementation waits for WMS-Meta #213/#214, WMS-BE #124 and WMS-FE #109 to merge. Then rebase, and re-anchor the PENDING and deferred-work line references.

## Boundaries & Constraints

**Always:**
- Everything lives in meta `infra/` and `.github/workflows/`.
- Every value that differs between environments is a variable set in `envs/<env>/terraform.tfvars`. Account ID, domain and zone are placeholders (`REPLACE_ME`, documented) because there is no real account here.
- Tags `project=wms`, `env`, `managed-by=terraform` go on every resource, through provider `default_tags`.
- IAM is least-privilege per role: the execution role reads only its environment's secrets and ECR; task roles get only their service's actions.
- DEPLOY.md gains §AWS: the bootstrap and apply order, setting the out-of-band secrets, enabling the pipeline (the role ARN variable and environment protection), the first deploy, rollback (re-run with the previous SHAs), and the 6-2c go-live gate.

**Never:**
- Never run `terraform apply`/`plan` against AWS, push images, call AWS APIs or create real resources. Only `fmt`/`init -backend=false`/`validate`, `actionlint` and docker builds, locally or in CI.
- No wms-be/wms-fe change and no DB migration.
- No long-lived AWS keys; OIDC only.
- No secret values in tfvars, the repo or workflow logs.
- No 6.3 scope: alarms, dashboards and tested restore stay out. This story has backups on, nothing more.
- No WAF or CDN (6.4/security, recorded in PENDING).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error handling |
|---|---|---|---|
| Unconfigured | `AWS_DEPLOY_ROLE_ARN_<ENV>` (repo variable) unset | The gate job prints "not configured", succeeds, and every later job is skipped | — |
| Promote | Production run with full SHAs that are in ECR and match `/wms/staging/deployed` | No build; migrate and roll use those images | A missing image or an unstaged SHA fails before migrate |
| Refused migration | Migrate task exits 2 | The workflow fails at migrate; services untouched | The message points to the DEPLOY.md pre-build step |
| Migrate crash | Exit ≠ 0, 2, or the task fails to start | The workflow fails; services untouched | The stopped reason is logged |
| Roll fails | The circuit breaker trips, or the PRIMARY deployment is not the new ARN | The A1 poll fails the job; ECS has rolled back | Later services are not rolled; the summary lists per-service status |
| Rollback | Previous SHAs with `skip_migrations=true` | Roll only; no migrate | — |
| First deploy | Services at desired 0 | The roll sets the target count from SSM | Missing out-of-band secrets → task fails to start → the job fails with `stoppedReason` |
| Not ready | `/health/ready` not 200 within 5 min after the api roll | The worker and web are not rolled; the job fails | — |
| Dry run | `dry_run_migrations=true` | The migrate task runs `--dry-run` with no provisioning; the workflow stops after it | Exit 2 is reported as "would refuse" |

</frozen-after-approval>

## Code Map

- `docs/design/DEPLOY.md` (from 6-2a, WMS-Meta #214): the deploy order (§3), the env split, ALB requirements (C28), roles, and the CONCURRENTLY table. Extend it with §AWS and correct the web-drain sentence (§1, C30).
- `deploy/compose.yml` / `deploy/.env.example` (6-2a): the canonical per-role env sets (api / worker / migrate / web) and `*_POLL_MS` values. Mirror them in the task definitions.
- wms-be (read-only):
  - `Dockerfile`: port 3000, `HEALTHCHECK /api/v1/health`.
  - `package.json` scripts `db:migrate:deploy` and `db:provision-roles`.
  - `.env.example`: the full variable list.
  - `src/modules/inventory/ledger-anchor-worm.ts:118-137`: the S3 actions (PutObject with COMPLIANCE retention, GetObject by version, ListBucket).
  - `src/shared/db/db.ts:12`: postgres.js reads `sslmode` from the URL.
  - `src/shared/valkey/valkey.client.ts:46`: ioredis accepts `rediss://:token@`.
- wms-fe (read-only): `Dockerfile` (port 3001, `scripts/start-standalone.mjs` requires `WMS_API_BASE_URL`). The FE CI checks out `chinnisasi/WMS-BE`, so cross-repo checkout from meta works.
- `spec-5-1a-email-service-and-invite-emails.md` (design WMS-Meta #210): the SES variables and the IAM actions.
- `docs/design/PENDING.md` §6-2b entries (PENDING:599, 600, 605–607, 200): close those this story covers and repoint C26/C30/C31/C19 to 6-2c.
- `_bmad-output/implementation-artifacts/deferred-work.md`, the 6-2b entries ("ECS Fargate … RDS Postgres" and "target-group fail-open …"): mark them covered or split. Re-anchor by text after the rebase (A16).
- New: `infra/{bootstrap,global,modules/environment,envs/staging,envs/production}/`, `infra/README.md`, `.github/workflows/{deploy.yml,infra-ci.yml}`. Add `.terraform/`, `*.tfstate*` and `.terraform.lock.hcl` handling to `.gitignore` (commit the lock files; ignore state and `.terraform/`).

## Tasks & Acceptance

**Execution:**
- [x] `infra/bootstrap/*.tf`: the state bucket (versioning, SSE-KMS, public access block, deny non-TLS); outputs the bucket name.
- [x] `infra/global/*.tf`: ECR repos with lifecycle, the OIDC provider (`token.actions.githubusercontent.com`), and per-environment deploy roles. Each role's trust is limited to the `environment:<env>` sub claim. Its policy covers ECR push/pull, ECS register/run/update/describe on its environment, `iam:PassRole` for its environment's task and execution roles only, SSM read of `/wms/<env>/deploy`, and logs read.
- [x] `infra/modules/environment/*.tf`: network, ALB/ACM/Route 53, ECS cluster, services, task definitions, autoscaling, RDS, Valkey, secrets, IAM roles, logs, the SSM deploy parameter, the S3 anchor bucket (gated by `ledger_anchor_worm`), and the SES identity. Variables carry descriptions and validations (e.g. `environment` ∈ staging|production, `api_desired_count ≥ 2` when production).
- [x] `infra/envs/{staging,production}/{main.tf,backend.tf,terraform.tfvars}`: module calls with the sizes and flags from the decisions; backend `key = "<env>/terraform.tfstate"`.
- [x] `.github/workflows/deploy.yml`: as decision 9.
- [x] `.github/workflows/infra-ci.yml`: fmt, validate (for each root, matrix) and actionlint.
- [x] `infra/README.md` + `docs/design/DEPLOY.md` §AWS (Boundaries list), plus the C30 correction. `docs/design/SYSTEM-DESIGN.md` deploy section: the topology diagram (mermaid). PENDING / deferred-work updated and the 6-2c entry added. `docs/repos/` contracts note the required production env per service.

**Acceptance Criteria:**
- Given the Terraform image (`hashicorp/terraform`, pinned to the same minor as `required_version`), when `fmt -check -recursive` runs, and `init -backend=false && validate` runs on each of the four roots, then all pass.
- Given `rhysd/actionlint`, when it runs over `.github/workflows`, then there are no findings.
- Given the production task definitions, when they are inspected (`terraform console`, or by reading the `.tf`), then no `*_POLL_MS` is on the API and every `*_POLL_MS` from compose is on the worker. Migrate alone gets the owner URL and the role passwords, and every secret is a `valueFrom` reference, never a literal.
- Given the worker service, then `desired_count = 1`, `deployment_minimum_healthy_percent = 0` and `deployment_maximum_percent = 100`, and it has no load balancer.
- Given the deploy role trust policy, then only `repo:chinnisasi/WMS-Meta:environment:<env>` can assume it.
- Given `deploy.yml` with no configured role, when it is dispatched, then only the gate job runs and it succeeds. This is checked by reading the `if:` conditions; `actionlint` passes.

## Design Notes

**Why the pipeline lives in meta:** both images and the one migrate-then-roll sequence span two repos, and the meta repo is the control plane (CLAUDE.md). Per-repo pipelines would need cross-repo triggers (a PAT) to order migrate before roll. Auto-deploying staging on each app-repo merge is a later convenience, recorded as deferred.

**Why task definitions are registered by the pipeline:** Terraform owns the shape (env, secrets, sizes), and the pipeline swaps only the image. `ignore_changes` stops `apply` from reverting a deploy. A Terraform change to the shape takes effect on the next pipeline run, which reads the latest revision. That is the accepted cost, documented in DEPLOY.md.

**Rollback** means re-running the pipeline with the previous SHAs. The schema only moves forward and migrations are additive (6-2a), so an old image over a newer schema stays ready.

## Verification

**Commands:**
- `docker run --rm -v "$PWD/infra":/infra -w /infra hashicorp/terraform:<pinned> fmt -check -recursive` -- expected: exit 0
- for each root: `... -w /infra/<root> hashicorp/terraform:<pinned> init -backend=false && ... validate` -- expected: "Success! The configuration is valid."
- `docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:<pinned>` -- expected: exit 0

## Implementation Notes

Implemented 2026-10-23 against `main` at `f23986d` (WMS-Meta #213/#214, WMS-BE #124 and WMS-FE #109 all merged, so A16's wait is satisfied; the PENDING and deferred-work entries were re-anchored by text, not line). Meta-only: no wms-be/wms-fe change, no migration.

**Files.** `infra/{bootstrap,global,modules/environment,envs/staging,envs/production}/`, `infra/README.md`, `infra/modules/environment/tests/environment.tftest.hcl`, `.github/workflows/{deploy.yml,infra-ci.yml}`, `.github/scripts/ecs-deploy.sh`, `.gitignore`; docs: `DEPLOY.md` (§8 AWS; §1/§2/§3/§7 corrections), `SYSTEM-DESIGN.md` (topology), `PENDING.md`, `deferred-work.md`, `docs/repos/wms-{be,fe}/README.md`.

**Resolved versions.** `hashicorp/aws` 6.70.0, `hashicorp/random` 3.9.1; Terraform 1.10.5 (CI and the docker commands). Actions pinned by SHA: `actions/checkout` v4.2.2 (`11bd719…`), `aws-actions/configure-aws-credentials` v4.3.1 (`7474bc4…`), `hashicorp/setup-terraform` v3.1.2 (`b9cd54a…`); `rhysd/actionlint:1.7.12` by digest. The build uses the runner's own `docker buildx` and AWS CLI (no build/ECR-login actions).

**Choices the spec left open, taken (recommended, autonomously):**
1. **Job vs step timeout (A4 × A8).** A8's `timeout-minutes: 60` was written for a migrate job; A4 merged migrate and roll into one `deploy` job. The 60-minute bound sits on the **Migrate step** (its poll is 45 minutes); the job's own is 170 (≤ 125 minutes of bounded work), below the deploy role's 180-minute session (`role-duration-seconds` = `max_session_duration` = 10800).
2. **First production apply passes `-var api_autoscaling=false`** (an A13 extension). Registering the scalable target with floor 2 would start API tasks immediately, before any image exists; the services are created at 0. Apply again without the flag after the first production deploy (`infra/README.md`, DEPLOY.md §8.3, PENDING).
3. **The ECS steps live in `.github/scripts/ecs-deploy.sh`** (migrate / roll / ready), shellchecked in CI, instead of 200 lines of inline YAML. `register_from_base` sets a global rather than echoing from a subshell, so a refusal's `::error::` reaches the log.
4. **Three execution roles, not one:** app (api + worker: app secrets), migrate (owner URL + role passwords only — A9), web (no secrets). Every family has a named task role (empty except the worker's) so the A2 role assertion always has two ARNs to compare.
5. **A dry run that would refuse (exit 2) fails the job** with "a real run WOULD REFUSE", so it shows red; a clean dry run succeeds and stops.
6. **The gate job carries no `if:`** — it must run to print "not configured". A configured run off `main` fails there; `build` and `deploy` repeat the `refs/heads/main` check (A3).
7. **The A6 privilege check runs through the migrate task** (no bastion): a dry run registers a revision with a real image, then a `run-task` override runs a `bun -e` postgres.js query. The exact command was run against the local `wms-be` image and Postgres 18 (`{"bypassrls":true,"read_all_stats_admin":true}` as a superuser) — DEPLOY.md §8.3. The first-time order therefore sets up the GitHub environments and role variables before the check (A13's order otherwise kept).
8. **Unknown hosts get a 404** from the HTTPS listener's default action (the bare `*.elb.amazonaws.com` name included), and HTTP → HTTPS is a 301.
9. **`EXPO_ACCESS_TOKEN`'s secret always exists** (no value); it is wired on the worker only when `push_gateway = "expo"`.
10. **Container health checks:** interval 15 s, timeout 5 s, retries 3, start period 30 s (A7 fixed only the start period).
11. **ACM validation records are keyed by the two static host names**, not by the certificate's computed options, so the instance keys never depend on an apply-time value.
12. **Lock files** cover `linux_amd64`, `darwin_arm64` and also `linux_arm64` (the Terraform Docker image on Apple silicon; without it a second local `init -lockfile=readonly` fails its cache check). A superset of A16.
13. **The bootstrap's first apply uses a git-ignored `local_override.tf`** (`backend "local" {}`) over its committed partial S3 backend, then `init -migrate-state` (A10).
14. **A mocked `terraform test`** (`modules/environment/tests/`) applies the module against mock providers — no AWS — and pins the acceptance criteria that read the task definitions, the worker service, the trust policy, push-on-staging-only and liveness health; CI runs it. A mutation (a `*_POLL_MS` on the API, worker minimum healthy 50) makes it fail.

**Recorded "verify at the first plan"** (AWS was not reachable): Postgres `18` / family `postgres18`, Valkey `8.1` / family `valkey8`, Performance Insights on `db.t4g.small`, the `aws:SourceArn` condition in the ECS task-role trust (applied to the execution roles too), and the RDS master user's privileges (A6). All in PENDING deploy and `infra/README.md`.

**Verification (all local, Docker; nothing reached AWS):**
- `terraform fmt -check -recursive` (1.10.5): exit 0.
- `init -backend=false -lockfile=readonly && validate` on bootstrap, global, envs/staging, envs/production and modules/environment: "Success! The configuration is valid." ×5, twice (a second run proves the cache matches the lock).
- `terraform test` in modules/environment: 3 passed (production shape, staging shape, the `api_desired_count ≥ 2` validation).
- `rhysd/actionlint:1.7.12` over the repo: no findings; `shellcheck` over `ecs-deploy.sh`: clean.
- `ecs-deploy.sh` against a stubbed `aws` CLI: migrate exit 0 / 2 / 137 / no exit code / `run-task` failures / dry run 0 and 2 / an injected `allow_locking`; roll first deploy (sets `--desired-count`), later deploy (does not), circuit-breaker rollback (PRIMARY on another revision), `FAILED`, a base revision with foreign roles, an unknown service. The copied revision drops the read-only fields and swaps only the image.
- The SYSTEM-DESIGN mermaid diagram renders (`minlag/mermaid-cli`).

## Spec Change Log

## Review Triage Log

Design review, 2026-10-22 (D). Two layers: a claims check against the code (K) and a blind reviewer (B). Every accepted finding is folded into amendments A1–A16 above. Choices are recommended, taken autonomously.

| ID | Src | Verdict | Finding → resolution |
|---|---|---|---|
| D1 | K,B | high | A circuit-breaker rollback still passes `services-stable`; the waiter's 10-minute cap. → A1 |
| D2 | K | high | Unscopable RegisterTaskDefinition + "latest revision" lets staging poison production; any branch can deploy; ECR tag pre-emption. → A2, A3 |
| D3 | K,B | high | "Never rebuilt" is not enforced; `main` defaults on production. → A3 |
| D4 | K | high | Environment-scoped variables are invisible to a gate job without an environment; one approval per job. → A4 |
| D5 | K | high | The env wiring misses LEDGER_ANCHOR on the API, WMS_API_BASE_URL, CORS_ORIGIN, PUSH/EWAY gateways, AWS_REGION; DEPLOY.md:96 is wrong. → A5 |
| D6 | K | high | Unverified: the RDS master's BYPASSRLS and ADMIN OPTION on pg_read_all_stats. → A6 (checks + go-live blocker; no invented fallback) |
| D7 | K | high | ALB health on `/ready` plus ECS replacement → every task recycled in a dependency outage. → A7 (liveness for the TG; readiness as the pipeline gate) |
| D8 | K | high | The spec context (DEPLOY.md, 6-2a spec) is not on main; the line references belong to another branch. → A16 (implementation waits for the merges; re-anchor) |
| D9 | K,B | medium | Migrate mechanics: the waiter cap, exit-code reading, dry-run command, no allow-locking input; rollback runs migrate. → A8 |
| D10 | K | medium | The owner-URL boundary is wiring only; the deploy role can read logs; the repos are public. → A9 |
| D11 | K,B | medium | Contradictory state access; staging can read production's credentials. → A10 |
| D12 | K,B | medium | Account model implicit; global needs environment ARNs; SES identity collides. → A11 |
| D13 | K | medium | ECR count-lifecycle expires running images; concurrent same-SHA push. → A12, A4 |
| D14 | K,B | medium | First apply has no images or secrets; Terraform deregisters running revisions. → A13 |
| D15 | K,B | medium | Fargate ignores the Dockerfile HEALTHCHECK; the worker has no health; no matcher. → A7 |
| D16 | K,B | medium | SES: no MAIL FROM/DMARC; IAM scope; EMAIL_SEAL_KEY would block task start. → A11, A5 |
| D17 | K | medium | S3 anchor actions unlisted; staging never runs the S3 path. → A15 |
| D18 | K | low | The keep-alive gate says Node; the BE runs Bun. → A16 |
| D19 | K,B | low | API count rationale, Valkey eviction/at-rest/windows, NAT endpoints, t4g credits, lock-file platforms, secrets via argv. → A14, A16 |
| D20 | B | medium | Production can deploy without approval if the ARN is set before the protection rule. → A4/A3 (main-only + environment rule; the runbook orders the rule before the variable) |
| D21 | B | low | RDS/ALB defaults unstated (final snapshot, windows, TLS policy, deletion protection, access logs). → A14 |
| D22 | B | low | Secrets recovery window blocks re-create; password rotation order. → A14, A16 |
| D23 | B | low | Bootstrap state only on a laptop. → A10 |
| D24 | B | low | Partial roll leaves mixed versions with no recovery. → A1 |
| D25 | B | — | Cookies leak across environments on a shared domain. → R: the refresh cookie is host-only, with no Domain attribute (`session-cookie.ts:23-33`, verified by K) |
| D26 | B | — | Private repos need a token for cross-repo checkout. → R: all three repos are public (K, `gh repo view`) |

Code review, 2026-10-23 (Blind Hunter BH, Edge Case Hunter EC, Verification Gap VG). Routing per step-04; all choices recommended, taken autonomously. Nothing was run against AWS.

| ID | Source | Verdict | Finding → route |
|---|---|---|---|
| C1 | VG1 | medium | `ecs-deploy.sh` (migrate exit mapping, rollback detection, first-deploy desired count, dry-run refusal) and the gate's input checks run in no CI test; the stub-`aws` harness used by hand is not committed. → patch: commit the harness and run it in `infra-ci.yml`. |
| C2 | VG2 | medium | The `/wms/<env>/deploy` parameter's keys (and migrate's `log_stream_prefix`/`container` matching the container's log options) are unchecked; a rename merges green and loses the migrate log. → patch: tftest assertions. |
| C3 | VG3 | medium | A9's execution-role secret split is untested, and the mocks give every secret and role one ARN, so no assertion could tell them apart. → patch: overrides with distinct ARNs + IAM-document assertions. |
| C4 | EC1, BH3 | medium | Deploy job `timeout-minutes: 150` exceeds the 7200 s role session; credentials can expire mid-roll. → patch: session 10800 s on both sides (`role-duration-seconds`, `max_session_duration`), job timeout under it, arithmetic stated once in DEPLOY §8. |
| C5 | EC2, EC9 | medium | A dry run drops a non-empty `allow_locking`, so it reports a refusal the real run would accept (A8 claim). → patch: pass `--allow-locking` to the dry run too. |
| C6 | EC3 | low | Parameter groups have fixed names with `create_before_destroy`; a family change cannot create the replacement. → patch: `name_prefix`. |
| C7 | EC4 | low | A production rollback with `skip_migrations` to a SHA older than staging's last deploy is refused. → patch (docs): DEPLOY §8 rollback — re-deploy staging at that SHA first, or use the ECS previous-revision rollback. |
| C8 | EC5, BH2 | low | Staging anchor objects never expire (Object Lock retention ending only makes them deletable); no lifecycle rule, no `force_destroy`. → patch: lifecycle expiry (current + noncurrent) and `force_destroy` in staging only. |
| C9 | EC6 | low | `api_max_count < api_desired_count` is caught only at apply. → patch: a variable validation. |
| C10 | EC7 | medium | A migrate task past its deadline keeps running and holding the advisory lock. → patch: `aws ecs stop-task` before failing. |
| C11 | EC8 | low | A missing deploy-parameter key reaches AWS calls as the literal `null`. → patch: `jq -er` + fail naming the key. |
| C12 | BH1 | false | Lock files are present in all five roots (excluded from the review diff only). → reject. |
| C13 | BH4 | false | The migrate log printing secrets: `provision-roles` prints role names only, `migrate-deploy` prints plan lines and error messages, never the URL or passwords (checked in wms-be). → reject. |
| C14 | BH5 | low | Ticked task text names the old placement (deploy roles in global, gated bucket, SES in the module). The fix edits this build's spec. → reject (Implementation Notes already record the moves). |
| C15 | BH6 | medium | The "new env var must be added to `ecs.tf`" rule lives only in the wms-be README, not in IMPLEMENTATION-GUIDE which specs load. → patch (docs); an automated drift check → defer. |
| C16 | BH7 | medium | CI never evaluates the committed `envs/*/terraform.tfvars` against the module; a broken decision value merges green. → patch: a `terraform test` in each env root (mock providers, plan, the root's tfvars load automatically) asserting the decision values. |
| C17 | BH8 | medium | The first production apply depends on remembering `-var api_autoscaling=false`. → defer (a precondition needs a source of truth for "an image exists"; DEPLOY §8 states the step). |
| C18 | BH9 | medium | The state bucket's operator-only policy can lock everyone out; the ARN validation does not check the account; the SSO example path assumes ap-south-1; no recovery documented. → patch: validation pins `account_id`, README example and a break-glass (root user deletes the bucket policy). |
| C19 | BH10 | low | Pipeline-registered task-definition revisions drop their tags (`describe` without `--include TAGS`); the jq strip list is verified against a stub only. → patch: carry tags; add the round-trip to the README's verify-at-first-deploy list. |
| C20 | BH11 | false | "Only the worker calls S3": the API's only ledger-integrity route reads stored state (`inventoryFacade.ledgerIntegrity`); `put`/`get` run from the worker's `runLedgerIntegrity`. → reject. |
| C21 | BH12 | medium | A6 has no fallback if the RDS master lacks BYPASSRLS/ADMIN on `pg_read_all_stats`. Already a recorded go-live blocker (PENDING deploy). → defer (no new entry; carried by 6-2c). |
| C22 | BH13 | low | PENDING's header counts were not updated. → patch. |
| C23 | BH14 | low | The global `wms-build` concurrency group can cancel a waiting staging run silently. → patch (docs, DEPLOY §8.5). |
| C24 | VG-other | low | The deploy role's actions and the pipeline's AWS calls match only by hand. → patch: add to the README's verify-at-first-plan list. |
