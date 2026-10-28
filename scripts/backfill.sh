#!/bin/bash
# backfill.sh - Loads DevOps Agent investigations that finished BEFORE the
# collection stack existed in an account and Region, then refreshes that
# collector's recommendations and status record.
#
# When to run: once, in each workload account that already had Agent Spaces
# with history when you deployed the collection stack. Agent Spaces created
# after deployment are captured live and never need a backfill.
# Also the repair step: after fixing any collection or replication failure,
# re-run it. It is idempotent - every record is written to the same S3 key,
# so re-runs overwrite in place and never duplicate.
#
# Usage: ./backfill.sh <REGION>[,<REGION>...] [--dry-run]
#   Runs against the account of the current AWS credentials.
#   --dry-run lists what would be backfilled and writes nothing; it works even
#   before the collection stack is deployed.
#
# How it works: ListAgentSpaces -> ListBacklogTasks (INVESTIGATION tasks that
# are COMPLETED, FAILED, or TIMED_OUT) -> the task's investigation execution ->
# the collector Lambda is invoked with an event shaped like the live
# EventBridge event. The collector is the only code that builds records, so a
# backfilled record is identical to a live one.
set -euo pipefail

REGIONS="${1:-}"
MODE="${2:-}"
if [ -z "${REGIONS}" ] || [ "${REGIONS}" = "--dry-run" ]; then
  echo "Usage: $0 <REGION>[,<REGION>...] [--dry-run]" >&2
  exit 2
fi
COLLECTOR_FN="devops-agent-investigation-collector"
INVENTORY_FN="devops-agent-inventory-collector"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
WORKDIR=$(mktemp -d)
trap 'rm -f "${WORKDIR}"/*; rmdir "${WORKDIR}"' EXIT

TOTAL_OK=0; TOTAL_SKIPPED=0; TOTAL_FAILED=0

# invoke <function> <payload-file> -> prints the function error type, or "OK"
invoke() {
  local fn="$1" payload="$2" region="$3" out="${WORKDIR}/response.json" err
  err=$(aws lambda invoke --function-name "${fn}" --payload "fileb://${payload}" \
        --region "${region}" --cli-read-timeout 330 --query FunctionError --output text "${out}") || {
    echo "INVOKE_FAILED"; return 0; }
  if [ "${err}" = "None" ] || [ -z "${err}" ]; then echo "OK"; return 0; fi
  sed -n 's/.*"errorType": *"\([^"]*\)".*/\1/p' "${out}" | head -1
}

for REGION in ${REGIONS//,/ }; do
  echo "=== Backfill ${ACCOUNT_ID} / ${REGION} ${MODE} ==="
  if [ "${MODE}" != "--dry-run" ] && \
     ! aws lambda get-function --function-name "${COLLECTOR_FN}" --region "${REGION}" >/dev/null 2>&1; then
    echo "  ERROR: ${COLLECTOR_FN} not found here. Deploy the collection stack in ${REGION} first."
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
    continue
  fi

  SPACES=$(aws devops-agent list-agent-spaces --region "${REGION}" \
    --query 'agentSpaces[].agentSpaceId' --output text)
  if [ -z "${SPACES}" ] || [ "${SPACES}" = "None" ]; then
    echo "  No Agent Spaces in this Region - nothing to backfill."
  fi

  for AS_ID in ${SPACES}; do
    [ "${AS_ID}" = "None" ] && continue
    echo "  Agent Space ${AS_ID}"
    # Task status is the reliable completion signal: a successful execution
    # reports STOPPED, and the execution enum has no COMPLETED value.
    TASKS=$(aws devops-agent list-backlog-tasks --agent-space-id "${AS_ID}" --region "${REGION}" \
      --query "tasks[?taskType=='INVESTIGATION' && contains(['COMPLETED','FAILED','TIMED_OUT'], status)].[taskId,status,priority,updatedAt]" \
      --output text)
    [ -z "${TASKS}" ] && { echo "    no finished investigations"; continue; }

    while IFS=$'\t' read -r TASK_ID STATUS PRIORITY UPDATED; do
      [ -z "${TASK_ID}" ] && continue
      if [ -z "${PRIORITY}" ] || [ "${PRIORITY}" = "None" ]; then PRIORITY="MEDIUM"; fi
      # The investigation execution is agentType ops1 (siblings are chat and mitigation).
      EXEC_ID=$(aws devops-agent list-executions --agent-space-id "${AS_ID}" --task-id "${TASK_ID}" \
        --region "${REGION}" --query "executions[?agentType=='ops1'] | [0].executionId" --output text)
      [ "${EXEC_ID}" = "None" ] && EXEC_ID=""
      if [ -z "${EXEC_ID}" ] && [ "${STATUS}" = "COMPLETED" ]; then
        echo "    SKIP ${TASK_ID}: completed but no investigation execution"
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1)); continue
      fi
      case "${STATUS}" in
        FAILED)    DETAIL_TYPE="Investigation Failed" ;;
        TIMED_OUT) DETAIL_TYPE="Investigation Timed Out" ;;
        *)         DETAIL_TYPE="Investigation Completed" ;;
      esac
      if [ "${MODE}" = "--dry-run" ]; then
        echo "    WOULD BACKFILL ${EXEC_ID:-task-${TASK_ID}} (${STATUS}, ${PRIORITY})"
        TOTAL_OK=$((TOTAL_OK + 1)); continue
      fi
      EXEC_FIELD=""
      [ -n "${EXEC_ID}" ] && EXEC_FIELD=", \"execution_id\": \"${EXEC_ID}\""
      cat > "${WORKDIR}/event.json" <<JSON
{"source": "aws.aidevops", "detail-type": "${DETAIL_TYPE}",
 "detail": {"version": "1.0.0",
   "metadata": {"agent_space_id": "${AS_ID}", "task_id": "${TASK_ID}"${EXEC_FIELD}},
   "data": {"task_type": "INVESTIGATION", "priority": "${PRIORITY}", "status": "${STATUS}", "updated_at": "${UPDATED}"}}}
JSON
      RESULT=$(invoke "${COLLECTOR_FN}" "${WORKDIR}/event.json" "${REGION}")
      case "${RESULT}" in
        OK) echo "    OK   ${EXEC_ID:-task-${TASK_ID}} (${STATUS})"; TOTAL_OK=$((TOTAL_OK + 1)) ;;
        NoInvestigationSummary)
            echo "    SKIP ${EXEC_ID}: no investigation summary (journal may have aged out)"
            TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1)) ;;
        *)  echo "    FAIL ${EXEC_ID:-task-${TASK_ID}}: ${RESULT}"; TOTAL_FAILED=$((TOTAL_FAILED + 1)) ;;
      esac
      sleep 0.2   # stay well inside DevOps Agent API rates
    done <<< "${TASKS}"
  done

  if [ "${MODE}" != "--dry-run" ]; then
    echo '{}' > "${WORKDIR}/empty.json"
    RESULT=$(invoke "${INVENTORY_FN}" "${WORKDIR}/empty.json" "${REGION}")
    if [ "${RESULT}" = "OK" ]; then
      echo "  Recommendations and collector status refreshed."
    else
      echo "  WARNING: inventory run returned ${RESULT}; see its CloudWatch Logs. The status record shows the error."
    fi
  fi
done

echo ""
echo "=== Summary: ${TOTAL_OK} backfilled, ${TOTAL_SKIPPED} skipped, ${TOTAL_FAILED} failed ==="
if [ "${MODE}" != "--dry-run" ] && [ "${TOTAL_OK}" -gt 0 ]; then
  echo "Records replicate to the dashboard account, usually within 15 minutes, and are queryable on arrival."
fi
if [ "${TOTAL_FAILED}" -gt 0 ]; then exit 1; fi
exit 0
