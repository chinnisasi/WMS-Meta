#!/usr/bin/env bash
# The `bash -c '… "$1"' _ <file>` assertions expand $1 in the child, on purpose.
# shellcheck disable=SC2016
# Story 6-2b — tests for .github/scripts/ecs-deploy.sh against a stubbed `aws`
# and `curl` on PATH. Nothing reaches AWS. Run: bash .github/scripts/tests/ecs-deploy.test.sh
# (infra-ci.yml runs it). Needs bash and jq.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/../ecs-deploy.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# ── the deploy parameter (the shape infra/modules/environment/ssm.tf writes) ──
cat >"$work/deploy.json" <<'JSON'
{"cluster":"wms-staging","subnets":["s1","s2"],"security_groups":["sg1"],
 "api_ready_url":"https://api.staging.example.in/api/v1/health/ready",
 "repositories":{"wms-be":"r/wms-be","wms-fe":"r/wms-fe"},
 "migrate":{"task_definition":"td-migrate:1","container":"migrate","execution_role_arn":"exec-m","task_role_arn":"task-m","log_group":"/wms/staging/migrate","log_stream_prefix":"migrate"},
 "services":{"api":{"service":"api","task_definition":"td-api:1","container":"api","target_count":2,"execution_role_arn":"exec-a","task_role_arn":"task-api"}}}
JSON
jq 'del(.migrate.task_role_arn)' "$work/deploy.json" >"$work/deploy-missing.json"

# ── the stub aws: behaviour chosen by STUB_* variables ──
cat >"$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >>"$STUB_DIR/calls"
case "$1 $2" in
  "ecs describe-task-definition")
    family=${4%%:*}
    if [[ $family == td-migrate ]]; then e=exec-m t=task-m c=migrate; else e=${STUB_EXEC:-exec-a} t=task-api c=api; fi
    jq -n --arg arn "arn:$4" --arg f "$family" --arg e "$e" --arg t "$t" --arg c "$c" '{
      taskDefinition: {taskDefinitionArn: $arn, revision: 1, status: "ACTIVE", requiresAttributes: [], compatibilities: ["FARGATE"],
        registeredAt: 1, registeredBy: "x", family: $f, executionRoleArn: $e, taskRoleArn: $t, enableFaultInjection: false,
        containerDefinitions: [{name: $c, image: "old", environment: [{name: "SOMETHING", value: "x"}]}]},
      tags: [{key: "project", value: "wms"}]}' ;;
  "ecs register-task-definition") cp "${4#file://}" "$STUB_DIR/registered.json"; echo "arn:new-rev" ;;
  "ecs run-task")
    if [[ -n "${STUB_RUN_FAIL:-}" ]]; then echo '{"tasks":[],"failures":[{"reason":"RESOURCE:ENI"}]}'
    else printf '%s\n' "$@" >"$STUB_DIR/runtask-args"; echo '{"tasks":[{"taskArn":"arn:task/wms-staging/abc123"}],"failures":[]}'; fi ;;
  "ecs describe-tasks")
    case "${STUB_EXIT:-0}" in
      running) echo '{"tasks":[{"lastStatus":"RUNNING","containers":[{"name":"migrate"}]}]}' ;;
      none) echo '{"tasks":[{"lastStatus":"STOPPED","stoppedReason":"ResourceInitializationError: unable to pull secrets","containers":[{"name":"migrate"}]}]}' ;;
      *) echo "{\"tasks\":[{\"lastStatus\":\"STOPPED\",\"stoppedReason\":\"Essential container exited\",\"containers\":[{\"name\":\"migrate\",\"exitCode\":$STUB_EXIT}]}]}" ;;
    esac ;;
  "ecs stop-task") echo STOPPED ;;
  "logs get-log-events")
    if [[ "$*" == *next-token* ]]; then echo '{"events":[],"nextForwardToken":"t1"}'
    else echo '{"events":[{"message":"plan: 2 pending"}],"nextForwardToken":"t1"}'; fi ;;
  "ecs describe-services")
    if [[ "$*" == *desiredCount* ]]; then echo "${STUB_DESIRED:-0}"
    else case "${STUB_ROLL:-ok}" in
      rollback) echo '{"services":[{"deployments":[{"status":"PRIMARY","taskDefinition":"arn:old","rolloutState":"IN_PROGRESS"}]}]}' ;;
      failed) echo '{"services":[{"deployments":[{"status":"PRIMARY","taskDefinition":"arn:new-rev","rolloutState":"FAILED","rolloutStateReason":"circuit breaker"}]}]}' ;;
      *) echo '{"services":[{"deployments":[{"status":"PRIMARY","taskDefinition":"arn:new-rev","rolloutState":"COMPLETED"}]}]}' ;;
    esac; fi ;;
  "ecs update-service") printf '%s\n' "$@" >"$STUB_DIR/update-args"; echo api ;;
  *) echo "stub aws: unexpected call: $*" >&2; exit 9 ;;
esac
STUB
cat >"$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${STUB_HTTP:-200}"
STUB
chmod +x "$work/bin/aws" "$work/bin/curl"

passed=0 failed=0
# check <name> <expected exit> <expected output substring> -- <env…> -- <args…>
check() {
  local name=$1 want_status=$2 want_text=$3
  shift 4
  local -a envs=()
  while [[ $1 != -- ]]; do envs+=("$1"); shift; done
  shift
  rm -f "$work/calls" "$work/registered.json" "$work/runtask-args" "$work/update-args"
  local out status
  out=$(env PATH="$work/bin:$PATH" STUB_DIR="$work" DEPLOY_JSON="$work/deploy.json" POLL_SECONDS=0 \
    BE_IMAGE=r/wms-be:sha1 DRY_RUN=false ${envs[@]+"${envs[@]}"} bash "$script" "$@" 2>&1)
  status=$?
  if [[ $status -eq $want_status && "$out" == *"$want_text"* ]]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL %s: exit %s (want %s), output lacks "%s":\n%s\n\n' "$name" "$status" "$want_status" "$want_text" "$out"
  fi
}
# expect <name> <condition…>: an extra assertion on the stub's records.
expect() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then passed=$((passed + 1)); else
    failed=$((failed + 1))
    echo "FAIL $name"
  fi
}

# ── migrate ──
check "migrate exit 0" 0 "Migrations applied; roles provisioned." -- STUB_EXIT=0 -- migrate
expect "migrate runs migrate then provision-roles" grep -qx 'bun run db:migrate:deploy && bun run db:provision-roles' <(jq -r '.containerOverrides[0].command[2]' <(sed -n '/--overrides/{n;p;}' "$work/runtask-args"))
expect "the copy swaps only the image" jq -e '.containerDefinitions[0].image == "r/wms-be:sha1" and .containerDefinitions[0].environment[0].name == "SOMETHING"' "$work/registered.json"
expect "the copy drops the read-only fields" jq -e '[has("taskDefinitionArn","revision","status","requiresAttributes","compatibilities","registeredAt","registeredBy")] | any | not' "$work/registered.json"
expect "the copy keeps the tags and new fields" jq -e '.tags == [{"key":"project","value":"wms"}] and has("enableFaultInjection")' "$work/registered.json"
check "migrate refused (exit 2)" 1 "::error::migration refused — see docs/design/DEPLOY.md §5" -- STUB_EXIT=2 -- migrate
check "migrate crash" 1 "::error::The migrate task exited 137 (Essential container exited); services untouched." -- STUB_EXIT=137 -- migrate
check "migrate never started" 1 "::error::The migrate task stopped without an exit code (TaskFailedToStart?): ResourceInitializationError" -- STUB_EXIT=none -- migrate
check "run-task failures" 1 "::error::The migrate task did not start; services untouched." -- STUB_RUN_FAIL=1 -- migrate
check "dry run clean" 0 "Dry run: the plan above applies cleanly." -- DRY_RUN=true STUB_EXIT=0 -- migrate
check "dry run would refuse" 1 "::error::Dry run: a real run WOULD REFUSE (exit 2)" -- DRY_RUN=true STUB_EXIT=2 -- migrate
check "dry run keeps allow_locking" 0 "command: bun run db:migrate:deploy --dry-run --allow-locking=idx_a,0078" -- DRY_RUN=true ALLOW_LOCKING=idx_a,0078 STUB_EXIT=0 -- migrate
expect "dry run provisions nothing" bash -c '! grep -q provision-roles "$1"' _ "$work/runtask-args"
check "real run allow_locking" 0 "command: bun run db:migrate:deploy --allow-locking=idx_a && bun run db:provision-roles" -- ALLOW_LOCKING=idx_a STUB_EXIT=0 -- migrate
check "bad allow_locking" 1 "::error::allow_locking may hold only letters" -- 'ALLOW_LOCKING=x;rm -rf /' -- migrate
check "migrate deadline stops the task" 1 "::error::The migrate task was still RUNNING after 0 minutes (arn:task/wms-staging/abc123) and has been stopped" -- STUB_EXIT=running MIGRATE_DEADLINE_SECONDS=0 -- migrate
expect "the deadline calls stop-task" grep -q 'aws ecs stop-task --cluster wms-staging --task arn:task/wms-staging/abc123 --reason deploy migrate deadline' "$work/calls"
check "missing parameter key" 1 "::error::deploy parameter lacks .migrate.task_role_arn" -- DEPLOY_JSON="$work/deploy-missing.json" STUB_EXIT=0 -- migrate
expect "a missing key runs nothing" bash -c '! grep -q run-task "$1"' _ "$work/calls"

# ── roll ──
check "first roll sets the count" 0 "api is at desired 0 (first deploy): setting it to 2." -- STUB_DESIRED=0 -- roll api r/wms-be:sha1
expect "first roll passes --desired-count 2" bash -c 'grep -A1 -x -- --desired-count "$1" | tail -1 | grep -qx 2' _ "$work/update-args"
check "later roll keeps the count" 0 "api: rolled (arn:new-rev)." -- STUB_DESIRED=2 -- roll api r/wms-be:sha1
expect "later roll passes no --desired-count" bash -c '! grep -qx -- --desired-count "$1"' _ "$work/update-args"
check "ECS rolled back" 1 "::error::api: the PRIMARY deployment runs arn:old, not arn:new-rev — ECS rolled back." -- STUB_ROLL=rollback -- roll api x
check "FAILED rollout" 1 "::error::api: the rollout FAILED" -- STUB_ROLL=failed -- roll api x
check "foreign roles" 1 "::error::td-api:1 does not carry this environment's execution and task roles" -- STUB_EXEC=exec-other -- roll api x
expect "foreign roles registers nothing" bash -c '! grep -q register-task-definition "$1"' _ "$work/calls"
check "unknown service" 1 "::error::No service nope in the deploy parameter." -- -- roll nope x

# ── ready ──
check "ready" 0 "answers 200" -- STUB_HTTP=200 -- ready
check "not ready" 1 "::error::https://api.staging.example.in/api/v1/health/ready answered 503" -- STUB_HTTP=503 READY_DEADLINE_SECONDS=0 -- ready

echo "ecs-deploy.sh: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
