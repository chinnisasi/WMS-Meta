# infra — the AWS environments (story 6-2b)

Terraform for WMS in AWS Mumbai (`ap-south-1`, D6): **staging** and **production** in one account, plus what they share. The deploy pipeline that runs on top of it is `.github/workflows/deploy.yml`; the operator's runbook — secrets, enabling the pipeline, first deploy, rollback — is **`docs/design/DEPLOY.md` §AWS**. This file covers the Terraform itself.

Nothing here has been applied: the account, the domain and the zone are `REPLACE_ME` placeholders, and CI only formats, validates and runs the module's mocked tests (`infra-ci.yml`).

## Layout

| Path | State key | What it holds |
|---|---|---|
| `bootstrap/` | `bootstrap/terraform.tfstate` (local on its first apply) | the state bucket (versioned, SSE-KMS, public access blocked, TLS-only, readable by the operator principal only) and its KMS key — both `prevent_destroy` |
| `global/` | `global/terraform.tfstate` | ECR `wms-be` / `wms-fe` (immutable tags, scan on push, untagged images expire after 7 days), the GitHub OIDC provider, the SES domain identity (Easy DKIM, MAIL FROM `mail.<domain>` with MX + SPF, DMARC `p=none`) |
| `modules/environment/` | — | everything one environment needs: VPC (2 AZs; public / app / data subnets; NAT; S3 gateway endpoint, interface endpoints in production), ALB + ACM + Route 53, the ECS cluster (api, worker, web services; the migrate task definition), API autoscaling, RDS Postgres 18, ElastiCache Valkey 8, Secrets Manager, IAM (execution, task and deploy roles), log groups, the ledger-anchor Object Lock bucket, the SSM deploy parameter |
| `envs/staging/`, `envs/production/` | `<env>/terraform.tfstate` | thin roots: sizes and flags in `terraform.tfvars` |

Tooling: Terraform `>= 1.10, < 2.0` (CI and the docker commands below pin **1.10.5**), `hashicorp/aws ~> 6.0`, `hashicorp/random ~> 3.6`. The provider lock files are committed for `linux_amd64` (CI), `darwin_arm64` (an Apple-silicon laptop) and `linux_arm64` (the Terraform Docker image on one); on another platform run `terraform providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=linux_arm64 -platform=<yours>` (after `init`, in an env root) and commit the result.

Tags `project=wms`, `env` (`staging`, `production` or `shared`) and `managed-by=terraform` reach every resource through the provider's `default_tags`.

## Who runs it

**Only an operator** — an admin SSO principal — runs Terraform, from a laptop (A10). The deploy roles cannot read the state: the bucket and its key deny every principal outside `operator_principal_arns`. The state holds the generated database and Valkey credentials (decision 7) — an accepted risk, because the bucket is encrypted, versioned and operator-only; moving them to write-only attributes is in `docs/design/PENDING.md` (deploy).

## Before the first apply

1. One AWS account (A11), with an admin SSO role for the operator.
2. A Route 53 **public hosted zone** for the domain, with the registrar's NS records pointing at it. The domain must be a registrable domain off the public suffix list (the cookie rule, `DEPLOY.md` §2).
3. Fill in every `REPLACE_ME` in `bootstrap/`, `global/` and both `envs/` `terraform.tfvars`, and commit them. The repository is public: the account ID, the domain, the zone ID and the SSO role pattern are the only account values in tfvars (A9) — never a secret.
4. Check the engine versions this config names still exist (they could not be checked here — AWS was not reachable when it was written):

   ```bash
   aws rds describe-db-engine-versions --engine postgres --query 'DBEngineVersions[?starts_with(EngineVersion, `18`)].EngineVersion'
   aws elasticache describe-cache-engine-versions --engine valkey --query 'CacheEngineVersions[].EngineVersion'
   ```

   The module defaults are `db_engine_version = "18"` (RDS picks the minor; minors upgrade automatically) with family `postgres18`, and `valkey_engine_version = "8.1"` with family `valkey8`.

### Verify at the first plan and the first staging deploy

Written without reaching AWS, so these are unproven until then (`docs/design/PENDING.md`, deploy):

- the engine versions and parameter-group families above, and Performance Insights on `db.t4g.small`;
- the `aws:SourceArn` / `aws:SourceAccount` conditions in the ECS roles' trust (the execution roles use them too): a task that cannot start with an `AccessDenied` on assume-role points here;
- the **describe → register round-trip**: the pipeline registers a copy of `describe-task-definition --include TAGS` with the read-only fields removed — a field AWS adds to the description later (such as `enableFaultInjection`) must still be accepted by `register-task-definition`;
- the **deploy role's actions against the calls the pipeline makes** (`.github/scripts/ecs-deploy.sh`, `deploy.yml`): ECR describe/push, `RegisterTaskDefinition` with tags (`ecs:TagResource` on create), `RunTask`, `DescribeTasks`, `StopTask`… — any `AccessDenied` in the first run names the gap;
- the RDS master user's privileges (A6, `DEPLOY.md` §8.3).

## Apply order

Every command runs in the stack's directory with the operator's credentials (`AWS_PROFILE`). `BUCKET` below is `wms-tfstate-<account>-ap-south-1`.

### 1. Bootstrap (once)

Its first apply runs on local state, because the bucket it would keep its state in does not exist yet:

```bash
cd infra/bootstrap
printf 'terraform {\n  backend "local" {}\n}\n' > local_override.tf   # git-ignored
terraform init
terraform apply
```

**Break-glass.** The bucket policy denies every principal outside `operator_principal_arns` (the variable must name the same account as `account_id`, or validation refuses it). If a wrong pattern locks everyone out anyway, sign in as the account's **root user**, which can always delete an S3 bucket policy (`aws s3api delete-bucket-policy --bucket $BUCKET`), fix the pattern and apply again. The KMS key policy has no such escape: KMS refuses a policy that would lock out its caller, and past that only AWS Support can restore access — so apply the bootstrap from a principal the patterns match.

Then move its state into the bucket it just made, and delete the local copy:

```bash
rm local_override.tf
terraform init -migrate-state \
  -backend-config="bucket=$BUCKET" -backend-config="key=bootstrap/terraform.tfstate" \
  -backend-config="region=ap-south-1" -backend-config="use_lockfile=true"
rm terraform.tfstate terraform.tfstate.backup
```

### 2. Global

```bash
cd infra/global
terraform init -backend-config="bucket=$BUCKET" -backend-config="key=global/terraform.tfstate" \
  -backend-config="region=ap-south-1" -backend-config="use_lockfile=true"
terraform apply
```

The SES identity verifies itself once its DKIM records resolve (minutes). A new account's SES is in the **sandbox** (it sends only to verified addresses) — request production access before 5-1a sends real mail. If the zone already carries a DMARC record, set `dmarc_record = null`.

### 3. Each environment — staging first

```bash
cd infra/envs/staging
terraform init -backend-config="bucket=$BUCKET" -backend-config="key=staging/terraform.tfstate" \
  -backend-config="region=ap-south-1" -backend-config="use_lockfile=true"
terraform apply
```

Production the same, with `key=production/terraform.tfstate` — and **on its first apply only**, `terraform apply -var api_autoscaling=false`. Autoscaling's floor (2) would otherwise start API tasks the moment it registers, before any image exists; the services are created at desired 0 (A13), and the first pipeline roll sets their counts. Apply again without the flag after the first production deploy.

What a new environment needs before its first deploy — the out-of-band secrets, the privilege checks, the GitHub environment and the role variable — is `DEPLOY.md` §AWS.

## What Terraform owns, and what the pipeline owns

Terraform owns the **shape**: each task definition's environment, secrets, sizes and roles. The services ignore `task_definition` and `desired_count`, so an apply never reverts a deploy, and task definitions are `skip_destroy`, so a shape change never deregisters the revision that is running.

The **pipeline** owns which image runs. It reads `/wms/<env>/deploy` (SSM, written by `ssm.tf`), copies the **base** revision named there, swaps only the image and registers it (A2). A shape change made by `apply` therefore reaches the running tasks at the **next pipeline run**, not at apply time.

The task definitions name the image tag `bootstrap` (`var.image_tag`), which never exists: those base revisions are templates and never run.

## Checking it locally

The same checks as `infra-ci.yml`, with nothing installed but Docker:

```bash
docker run --rm -v "$PWD/infra":/infra -w /infra hashicorp/terraform:1.10.5 fmt -check -recursive
for root in bootstrap global envs/staging envs/production modules/environment; do
  docker run --rm -v "$PWD/infra":/infra -w /infra/$root hashicorp/terraform:1.10.5 init -backend=false -lockfile=readonly
  docker run --rm -v "$PWD/infra":/infra -w /infra/$root hashicorp/terraform:1.10.5 validate
done
for root in modules/environment envs/staging envs/production; do
  docker run --rm -v "$PWD/infra":/infra -w /infra/$root hashicorp/terraform:1.10.5 test
done
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:1.7.12
bash .github/scripts/tests/ecs-deploy.test.sh   # the deploy script against a stubbed aws CLI
```

Each env root's `tests/` plans its committed `terraform.tfvars` through the module (mock providers, only the account values supplied) and asserts that environment's decisions.

`terraform test` applies the module against **mock** providers (no AWS call, nothing created) and asserts its load-bearing shape: no `*_POLL_MS` on the API and every one on the worker, the owner URL and role passwords on the migrate task only, every secret a `valueFrom`, the worker stop-then-start with no load balancer, each deploy role trusting only its own GitHub environment, push on the staging role only, and the API target group on liveness.
