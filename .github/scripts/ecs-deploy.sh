#!/usr/bin/env bash
# Story 6-2b — the deploy job's ECS steps, called by .github/workflows/deploy.yml.
#
#   ecs-deploy.sh migrate             run the one-shot migrate task (A8)
#   ecs-deploy.sh roll <service> <image>
#                                     roll api | worker | web onto <image> (A1, A2, A13)
#   ecs-deploy.sh ready               wait for the API's /health/ready (A7)
#
# Inputs (environment): DEPLOY_JSON — a file holding the SSM parameter
# /wms/<env>/deploy that Terraform writes (infra/modules/environment/ssm.tf).
# migrate also reads BE_IMAGE, DRY_RUN (true|false) and ALLOW_LOCKING.
#
# NEVER print a task definition, a container's environment or a secret: the
# repositories and the workflow logs are public (A8, A9). Task definitions go
# to temporary files and only their ARNs are echoed.
set -euo pipefail

: "${DEPLOY_JSON:?DEPLOY_JSON must name the deploy parameter file}"

MIGRATE_DEADLINE_SECONDS=${MIGRATE_DEADLINE_SECONDS:-2700} # 45 minutes (A8)
ROLL_DEADLINE_SECONDS=${ROLL_DEADLINE_SECONDS:-1200}       # 20 minutes per service (A1)
READY_DEADLINE_SECONDS=${READY_DEADLINE_SECONDS:-300}      # 5 minutes (A7)
POLL_SECONDS=${POLL_SECONDS:-15}

fail() {
  echo "::error::$*"
  exit 1
}

# Reads one key of the deploy parameter into PARAM. A missing (or null) key
# fails the run — never the literal "null". No subshell, so the ::error::
# reaches the log.
PARAM=""
param() {
  PARAM=$(jq -er "$1" "$DEPLOY_JSON") || fail "deploy parameter lacks $1"
}

param .cluster
CLUSTER=$PARAM

# Copies the BASE revision Terraform named (never "latest" — A2), asserts it
# still carries this environment's roles, swaps only <container>'s image and
# registers it. Sets REGISTERED_ARN (no subshell, so a refusal's ::error::
# reaches the log and stops the script).
REGISTERED_ARN=""
register_from_base() {
  local base=$1 container=$2 image=$3 exec_role=$4 task_role=$5
  local work actual_exec actual_task
  work=$(mktemp -d)

  # With its tags (Terraform's default_tags), which the copy keeps.
  aws ecs describe-task-definition --task-definition "$base" --include TAGS --output json >"$work/described.json"
  jq '.taskDefinition' "$work/described.json" >"$work/base.json"

  actual_exec=$(jq -r '.executionRoleArn // ""' "$work/base.json")
  actual_task=$(jq -r '.taskRoleArn // ""' "$work/base.json")
  if [[ "$actual_exec" != "$exec_role" || "$actual_task" != "$task_role" ]]; then
    rm -rf "$work"
    fail "$base does not carry this environment's execution and task roles — refusing to copy it (A2)."
  fi
  if ! jq -e --arg c "$container" '[.containerDefinitions[] | select(.name == $c)] | length == 1' "$work/base.json" >/dev/null; then
    rm -rf "$work"
    fail "$base has no single container named $container."
  fi

  jq --arg c "$container" --arg image "$image" --slurpfile described "$work/described.json" '
    del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities,
        .registeredAt, .registeredBy, .deregisteredAt)
    | .containerDefinitions |= map(if .name == $c then .image = $image else . end)
    | ($described[0].tags // []) as $tags
    | if ($tags | length) > 0 then .tags = $tags else . end
  ' "$work/base.json" >"$work/next.json"

  REGISTERED_ARN=$(aws ecs register-task-definition --cli-input-json "file://$work/next.json" \
    --query taskDefinition.taskDefinitionArn --output text)
  rm -rf "$work"
}

# Prints the migrate container's log stream (its messages only), oldest first.
print_migrate_log() {
  local task_id=$1 group stream token next page
  param .migrate.log_group
  group=$PARAM
  param .migrate.log_stream_prefix
  stream=$PARAM
  param .migrate.container
  stream="$stream/$PARAM/$task_id"
  echo "::group::migrate log ($stream)"
  token=""
  while :; do
    if [[ -z "$token" ]]; then
      page=$(aws logs get-log-events --log-group-name "$group" --log-stream-name "$stream" \
        --start-from-head --output json 2>/dev/null) || {
        echo "(no log stream — the task may not have started)"
        break
      }
    else
      page=$(aws logs get-log-events --log-group-name "$group" --log-stream-name "$stream" \
        --start-from-head --next-token "$token" --output json) || break
    fi
    jq -r '.events[].message' <<<"$page"
    next=$(jq -r '.nextForwardToken // ""' <<<"$page")
    [[ -z "$next" || "$next" == "$token" ]] && break
    token=$next
  done
  echo "::endgroup::"
}

cmd_migrate() {
  : "${BE_IMAGE:?}" "${DRY_RUN:?}"
  local allow=${ALLOW_LOCKING:-} container base arn shell_command overrides network run failures
  local task_arn task_id deadline described status exit_code stopped_reason

  # The gate validated it already; checked again because it reaches a shell.
  [[ "$allow" =~ ^[A-Za-z0-9_,-]*$ ]] || fail "allow_locking may hold only letters, digits, _ , and -."

  local exec_role task_role
  param .migrate.container
  container=$PARAM
  param .migrate.task_definition
  base=$PARAM
  param .migrate.execution_role_arn
  exec_role=$PARAM
  param .migrate.task_role_arn
  task_role=$PARAM
  param .subnets
  param .security_groups
  register_from_base "$base" "$container" "$BE_IMAGE" "$exec_role" "$task_role"
  arn=$REGISTERED_ARN
  echo "migrate revision: $arn"

  if [[ "$DRY_RUN" == "true" ]]; then
    # The plan honours the same accepted refusals the real run would.
    shell_command="bun run db:migrate:deploy --dry-run${allow:+ --allow-locking=$allow}"
  elif [[ -n "$allow" ]]; then
    shell_command="bun run db:migrate:deploy --allow-locking=$allow && bun run db:provision-roles"
  else
    shell_command="bun run db:migrate:deploy && bun run db:provision-roles"
  fi
  echo "command: $shell_command"

  overrides=$(jq -nc --arg c "$container" --arg s "$shell_command" '{containerOverrides: [{name: $c, command: ["sh", "-c", $s]}]}')
  network=$(jq -c '{awsvpcConfiguration: {subnets: .subnets, securityGroups: .security_groups, assignPublicIp: "DISABLED"}}' "$DEPLOY_JSON")

  run=$(aws ecs run-task --cluster "$CLUSTER" --task-definition "$arn" --launch-type FARGATE --count 1 \
    --network-configuration "$network" --overrides "$overrides" \
    --started-by "gh-deploy-${GITHUB_RUN_ID:-local}" --output json)

  failures=$(jq '.failures | length' <<<"$run")
  if [[ "$failures" != "0" ]]; then
    jq -r '.failures[] | "run-task failure: \(.reason // "?") \(.detail // "") \(.arn // "")"' <<<"$run"
    fail "The migrate task did not start; services untouched."
  fi
  task_arn=$(jq -r '.tasks[0].taskArn' <<<"$run")
  task_id=${task_arn##*/}
  echo "migrate task: $task_arn"

  deadline=$((SECONDS + MIGRATE_DEADLINE_SECONDS))
  while :; do
    described=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task_arn" --output json)
    status=$(jq -r '.tasks[0].lastStatus // "UNKNOWN"' <<<"$described")
    [[ "$status" == "STOPPED" ]] && break
    if ((SECONDS >= deadline)); then
      # Stop it: a running migrator holds the advisory lock, and the next
      # deploy's migrator would queue behind it.
      aws ecs stop-task --cluster "$CLUSTER" --task "$task_arn" --reason "deploy migrate deadline" \
        --query 'task.lastStatus' --output text >/dev/null || true
      print_migrate_log "$task_id"
      fail "The migrate task was still $status after $((MIGRATE_DEADLINE_SECONDS / 60)) minutes ($task_arn) and has been stopped; services untouched."
    fi
    sleep "$POLL_SECONDS"
  done

  print_migrate_log "$task_id"

  exit_code=$(jq -r --arg c "$container" '.tasks[0].containers[] | select(.name == $c) | .exitCode // empty' <<<"$described")
  stopped_reason=$(jq -r '.tasks[0].stoppedReason // ""' <<<"$described")

  if [[ -z "$exit_code" ]]; then
    fail "The migrate task stopped without an exit code (TaskFailedToStart?): $stopped_reason — e.g. an out-of-band secret with no value (DEPLOY.md §AWS). Services untouched."
  fi
  case "$exit_code" in
    0)
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "Dry run: the plan above applies cleanly. Nothing was changed; the deploy stops here."
      else
        echo "Migrations applied; roles provisioned."
      fi
      ;;
    2)
      if [[ "$DRY_RUN" == "true" ]]; then
        fail "Dry run: a real run WOULD REFUSE (exit 2) — see the plan above and docs/design/DEPLOY.md §5 (pre-build the index CONCURRENTLY, or name it in allow_locking). Nothing was changed."
      fi
      fail "migration refused — see docs/design/DEPLOY.md §5 (pre-build the index CONCURRENTLY, or name it in allow_locking). Nothing was applied; services untouched."
      ;;
    *)
      fail "The migrate task exited $exit_code ($stopped_reason); services untouched."
      ;;
  esac
}

cmd_roll() {
  local svc=${1:?service} image=${2:?image}
  local spec name container target arn current deadline described primary state reason td
  local base exec_role task_role
  spec=".services.$svc"
  jq -e --arg s "$svc" '.services | has($s)' "$DEPLOY_JSON" >/dev/null || fail "No service $svc in the deploy parameter."

  param "$spec.service"
  name=$PARAM
  param "$spec.container"
  container=$PARAM
  param "$spec.target_count"
  target=$PARAM
  param "$spec.task_definition"
  base=$PARAM
  param "$spec.execution_role_arn"
  exec_role=$PARAM
  param "$spec.task_role_arn"
  task_role=$PARAM
  register_from_base "$base" "$container" "$image" "$exec_role" "$task_role"
  arn=$REGISTERED_ARN
  echo "$svc revision: $arn"

  # A13: services are created at desired 0; the first roll sets the target.
  current=$(aws ecs describe-services --cluster "$CLUSTER" --services "$name" --query 'services[0].desiredCount' --output text)
  local count_args=()
  if [[ "$current" == "0" ]]; then
    echo "$svc is at desired 0 (first deploy): setting it to $target."
    count_args=(--desired-count "$target")
  fi

  aws ecs update-service --cluster "$CLUSTER" --service "$name" --task-definition "$arn" ${count_args[@]+"${count_args[@]}"} \
    --query 'service.serviceName' --output text >/dev/null

  # A1: our own bounded poll, never `wait services-stable` (a circuit-breaker
  # rollback also ends "stable", and the waiter gives up at 10 minutes).
  deadline=$((SECONDS + ROLL_DEADLINE_SECONDS))
  while :; do
    described=$(aws ecs describe-services --cluster "$CLUSTER" --services "$name" --output json)
    primary=$(jq -c '[.services[0].deployments[] | select(.status == "PRIMARY")][0] // {}' <<<"$described")
    td=$(jq -r '.taskDefinition // ""' <<<"$primary")
    state=$(jq -r '.rolloutState // ""' <<<"$primary")
    reason=$(jq -r '.rolloutStateReason // ""' <<<"$primary")

    if [[ "$td" != "$arn" ]]; then
      fail "$svc: the PRIMARY deployment runs $td, not $arn — ECS rolled back. $reason"
    fi
    case "$state" in
      COMPLETED)
        echo "$svc: rolled ($arn)."
        return 0
        ;;
      FAILED)
        fail "$svc: the rollout FAILED — the circuit breaker rolls it back. $reason"
        ;;
    esac
    if ((SECONDS >= deadline)); then
      fail "$svc: still $state after $((ROLL_DEADLINE_SECONDS / 60)) minutes."
    fi
    sleep "$POLL_SECONDS"
  done
}

cmd_ready() {
  local url deadline code
  param .api_ready_url
  url=$PARAM
  deadline=$((SECONDS + READY_DEADLINE_SECONDS))
  while :; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" || true)
    if [[ "$code" == "200" ]]; then
      echo "ready: $url answers 200."
      return 0
    fi
    if ((SECONDS >= deadline)); then
      fail "$url answered $code, not 200, for $((READY_DEADLINE_SECONDS / 60)) minutes — the worker and web are not rolled (A7)."
    fi
    echo "not ready yet ($code)"
    sleep 10
  done
}

case "${1:-}" in
  migrate) cmd_migrate ;;
  roll) cmd_roll "${2:-}" "${3:-}" ;;
  ready) cmd_ready ;;
  *) fail "usage: ecs-deploy.sh migrate | roll <api|worker|web> <image> | ready" ;;
esac
