#!/bin/bash
# backfill-historical.sh
#
# Loads DevOps Agent investigations that completed BEFORE this solution was
# deployed. EventBridge only fires on new events, so pre-deployment
# investigations are otherwise invisible to the dashboard.
#
# Run this IN EACH WORKLOAD ACCOUNT, after the collection stack is deployed.
#
# Usage: ./backfill-historical.sh [REGION] [--dry-run]
#
# How it works
# ------------
#   ListAgentSpaces  ->  ListBacklogTasks(agentSpaceId)        [filter + priority]
#                    ->  ListExecutions(agentSpaceId, taskId)  [executionId]
#                    ->  invoke collector Lambda
#
# Only tasks with taskType=INVESTIGATION and status=COMPLETED are replayed.
# Observed taskType values also include SYSTEM_LEARNING and EVALUATION, which
# produce no investigation summary and would be wasted invocations.
#
# status comes from the TASK, not the execution: a successful execution reports
# executionStatus=STOPPED, and the Execution enum
# (FAILED|RUNNING|STOPPED|CANCELED|TIMED_OUT) has no COMPLETED value at all.
# priority also comes from the task; it is not on the Execution object.
#
# This script deliberately does NOT compute timestamps. The collector Lambda
# derives Time to RCA from journal records (earliest record -> the
# investigation_summary record), which is what makes a backfilled row identical
# to a live one. Computing a time here too would be a second implementation of
# the same thing, free to drift.
#
# Because the collector's S3 key is a pure function of
# accountId / agentSpaceId / executionId, this script is safe to re-run:
# repeated runs overwrite in place rather than creating duplicates.
set -euo pipefail

REGION="${1:-us-east-1}"
DRY_RUN="${2:-}"
COLLECTOR_FN="devops-agent-investigation-collector"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== DevOps Agent Historical Backfill ==="
echo "Account: ${ACCOUNT_ID}"
echo "Region:  ${REGION}"
[ "${DRY_RUN}" = "--dry-run" ] && echo "Mode:    DRY RUN (no Lambda invocations)"
echo ""

# Confirm the collector exists before doing discovery work. Skipped for
# --dry-run so discovery can be validated before the stack is deployed.
if [ "${DRY_RUN}" != "--dry-run" ]; then
  if ! aws lambda get-function --function-name "${COLLECTOR_FN}" --region "${REGION}" >/dev/null 2>&1; then
    echo "ERROR: Lambda '${COLLECTOR_FN}' not found in ${ACCOUNT_ID}/${REGION}."
    echo "Deploy the collection stack (Step 2) before running backfill."
    echo "To validate discovery without deploying, re-run with --dry-run."
    exit 1
  fi
fi

TOTAL_SPACES=0
TOTAL_TASKS=0
TOTAL_EXECUTIONS=0
TOTAL_INVOKED=0
TOTAL_SKIPPED=0
TOTAL_FAILED=0

# ---------------------------------------------------------------------------
# Level 1: AgentSpaces
# ---------------------------------------------------------------------------
AGENTSPACES=$(aws devops-agent list-agent-spaces \
  --region "${REGION}" \
  --query 'agentSpaces[].agentSpaceId' \
  --output text 2>/dev/null || echo "")

if [ -z "${AGENTSPACES}" ]; then
  echo "No AgentSpaces found. Nothing to backfill."
  exit 0
fi

for AS_ID in ${AGENTSPACES}; do
  TOTAL_SPACES=$((TOTAL_SPACES + 1))

  # Resolve the workload tag for logging. The Lambda re-resolves this itself,
  # so a failure here is cosmetic only.
  WORKLOAD=$(aws devops-agent get-agent-space \
    --agent-space-id "${AS_ID}" \
    --region "${REGION}" \
    --query 'tags.workload' \
    --output text 2>/dev/null || echo "unknown")
  [ "${WORKLOAD}" = "None" ] && WORKLOAD="untagged"

  echo "AgentSpace ${AS_ID} (workload=${WORKLOAD})"

  if [ "${WORKLOAD}" = "untagged" ]; then
    echo "  WARNING: no 'workload' tag - rows will show workloadName=unknown."
    echo "           Tag the AgentSpace and re-run to correct this."
  fi

  # -------------------------------------------------------------------------
  # Level 2: Backlog tasks
  #
  # Filter to completed investigations, and take priority. taskType also takes
  # SYSTEM_LEARNING and EVALUATION, neither of which produces an investigation
  # summary. status and priority are task-level fields with no execution
  # equivalent, so those we take from here.
  #
  # Deliberately NOT taking executionId or updatedAt from the task: task
  # timestamps drift forward on any later activity against the task (see the
  # header note). Completion time must come from the investigation execution.
  # -------------------------------------------------------------------------
  TASKS=$(aws devops-agent list-backlog-tasks \
    --agent-space-id "${AS_ID}" \
    --region "${REGION}" \
    --query 'tasks[?taskType==`INVESTIGATION` && status==`COMPLETED`].[taskId,priority]' \
    --output text 2>/dev/null || echo "")

  if [ -z "${TASKS}" ]; then
    echo "  No completed investigation tasks."
    continue
  fi

  while IFS=$'\t' read -r TASK_ID PRIORITY; do
    [ -z "${TASK_ID}" ] && continue
    TOTAL_TASKS=$((TOTAL_TASKS + 1))

    # Normalize priority. Real values: CRITICAL|HIGH|MEDIUM|LOW|MINIMAL.
    if [ -z "${PRIORITY}" ] || [ "${PRIORITY}" = "None" ]; then
      PRIORITY="MEDIUM"
    fi

    # -----------------------------------------------------------------------
    # The investigation execution.
    #
    # agentType 'ops1' is the investigation agent. Sibling executions under the
    # same task are 'mitigation' and 'taskChat' -- both excluded.
    #
    # Only the executionId is needed. Timing is NOT read here: the collector
    # Lambda derives both endpoints from journal records itself, so anything
    # this script passed would be ignored. Deriving it here as well would just
    # be a second, divergent implementation of the same calculation.
    # -----------------------------------------------------------------------
    EXEC_ID=$(aws devops-agent list-executions \
      --agent-space-id "${AS_ID}" \
      --task-id "${TASK_ID}" \
      --region "${REGION}" \
      --query 'executions[?agentType==`ops1`] | [0].executionId' \
      --output text 2>/dev/null || echo "")

    if [ -z "${EXEC_ID}" ] || [ "${EXEC_ID}" = "None" ]; then
      echo "  SKIP task ${TASK_ID} - no ops1 investigation execution found"
      TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
      continue
    fi

    TOTAL_EXECUTIONS=$((TOTAL_EXECUTIONS + 1))

    # Synthesize the EventBridge event. Shape must match the live event so the
    # Lambda takes exactly the same code path. Field placement follows the
    # documented event schema: status and priority live under detail.data.
    #
    # No "time" field is supplied. The collector derives both timing endpoints
    # from journal records, which is what makes backfilled rows identical to
    # live ones. Passing a time here would be ignored, and including one would
    # imply it mattered.
    EVENT=$(cat <<JSON
{
  "source": "aws.aidevops",
  "detail-type": "Investigation Completed",
  "detail": {
    "version": "1.0.0",
    "metadata": {
      "agent_space_id": "${AS_ID}",
      "task_id": "${TASK_ID}",
      "execution_id": "${EXEC_ID}"
    },
    "data": {
      "task_type": "INVESTIGATION",
      "priority": "${PRIORITY}",
      "status": "COMPLETED"
    }
  }
}
JSON
)

    if [ "${DRY_RUN}" = "--dry-run" ]; then
      echo "  WOULD BACKFILL ${EXEC_ID} (priority=${PRIORITY})"
      TOTAL_INVOKED=$((TOTAL_INVOKED + 1))
      continue
    fi

    EVENT_FILE=$(mktemp)
    printf '%s' "${EVENT}" > "${EVENT_FILE}"
    RESP_FILE=$(mktemp)

    if aws lambda invoke \
        --function-name "${COLLECTOR_FN}" \
        --payload "fileb://${EVENT_FILE}" \
        --region "${REGION}" \
        "${RESP_FILE}" >/dev/null 2>&1; then
      if grep -q '"statusCode": 200' "${RESP_FILE}" 2>/dev/null; then
        if grep -q 'No summary record found' "${RESP_FILE}" 2>/dev/null; then
          echo "  SKIP ${EXEC_ID} - no investigation_summary in journal"
          TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
        else
          echo "  OK   ${EXEC_ID} (priority=${PRIORITY})"
          TOTAL_INVOKED=$((TOTAL_INVOKED + 1))
        fi
      else
        echo "  FAIL ${EXEC_ID} - $(head -c 200 "${RESP_FILE}")"
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
      fi
    else
      echo "  FAIL ${EXEC_ID} - Lambda invocation error"
      TOTAL_FAILED=$((TOTAL_FAILED + 1))
    fi

    rm -f "${EVENT_FILE}" "${RESP_FILE}"

    # Stay well inside DevOps Agent API throttling limits.
    sleep 0.3

  done <<< "${TASKS}"
done

echo ""
echo "=== Backfill Summary ==="
echo "  AgentSpaces scanned:      ${TOTAL_SPACES}"
echo "  Investigation tasks:      ${TOTAL_TASKS}"
echo "  With execution assigned:  ${TOTAL_EXECUTIONS}"
echo "  Backfilled:               ${TOTAL_INVOKED}"
echo "  Skipped:                  ${TOTAL_SKIPPED}"
echo "  Failed:                   ${TOTAL_FAILED}"
echo ""

if [ "${DRY_RUN}" != "--dry-run" ] && [ "${TOTAL_INVOKED}" -gt 0 ]; then
  echo "Next steps:"
  echo "  1. Wait 1-2 minutes for S3 replication to the dashboard account"
  echo "  2. In the dashboard account, run the Glue crawler:"
  echo "     aws glue start-crawler --name devops-agent-crawler-<dashboard-account-id>"
  echo "  3. Refresh QuickSight"
fi

[ "${TOTAL_FAILED}" -gt 0 ] && exit 1
exit 0
