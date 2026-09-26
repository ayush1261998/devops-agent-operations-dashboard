#!/bin/bash
# setup-dashboard.sh — Creates the QuickSight data source, datasets, and analysis.
# Usage: ./setup-dashboard.sh <ACCOUNT_ID> <REGION>
#
# Idempotent: every resource is created if absent and updated in place if present.
# An earlier version used `create ... || echo "(already exists)"`, which silently
# kept a stale dataset whenever the SQL changed — the script reported success while
# the dashboard queried the old columns. Each dataset now falls back to an explicit
# update, so re-running this script always converges on the definition in this repo.
set -euo pipefail

ACCOUNT_ID="${1:?Usage: setup-dashboard.sh <ACCOUNT_ID> <REGION>}"
REGION="${2:-us-east-1}"
GLUE_DB="devops_agent_dashboard"
TABLE="investigations_v2"
REC_TABLE="recommendations_v1"
ANALYSIS_ID="devops-agent-operations-dashboard"
ANALYSIS_NAME="DevOps Agent - Operations Dashboard"

echo "=== DevOps Agent Dashboard Setup ==="
echo "Account: ${ACCOUNT_ID}"
echo "Region:  ${REGION}"

# QuickSight identity that will own the resources.
QS_USER=$(aws quicksight list-users --aws-account-id "${ACCOUNT_ID}" --namespace default \
  --region "${REGION}" --query 'UserList[0].Arn' --output text)
if [ -z "${QS_USER}" ] || [ "${QS_USER}" = "None" ]; then
  echo "ERROR: No QuickSight user found in ${ACCOUNT_ID}/${REGION}."
  echo "Enable QuickSight (Enterprise edition) in this account first."
  exit 1
fi
echo "QuickSight User: ${QS_USER}"

DS_ID="devops-agent-athena-ds"
DS_ARN="arn:aws:quicksight:${REGION}:${ACCOUNT_ID}:datasource/${DS_ID}"

DATASET_PERMS="[{\"Principal\":\"${QS_USER}\",\"Actions\":[\"quicksight:DescribeDataSet\",\"quicksight:DescribeDataSetPermissions\",\"quicksight:PassDataSet\",\"quicksight:DescribeIngestion\",\"quicksight:ListIngestions\",\"quicksight:UpdateDataSet\",\"quicksight:DeleteDataSet\",\"quicksight:CreateIngestion\",\"quicksight:CancelIngestion\",\"quicksight:UpdateDataSetPermissions\"]}]"
SOURCE_PERMS="[{\"Principal\":\"${QS_USER}\",\"Actions\":[\"quicksight:DescribeDataSource\",\"quicksight:DescribeDataSourcePermissions\",\"quicksight:PassDataSource\",\"quicksight:UpdateDataSource\",\"quicksight:DeleteDataSource\",\"quicksight:UpdateDataSourcePermissions\"]}]"
ANALYSIS_PERMS="[{\"Principal\":\"${QS_USER}\",\"Actions\":[\"quicksight:RestoreAnalysis\",\"quicksight:UpdateAnalysisPermissions\",\"quicksight:DeleteAnalysis\",\"quicksight:DescribeAnalysisPermissions\",\"quicksight:QueryAnalysis\",\"quicksight:DescribeAnalysis\",\"quicksight:UpdateAnalysis\"]}]"
TAGS='[{"Key":"Project","Value":"devops-agent-dashboard"}]'

# create_or_update_dataset <dataset-id> <display-name> <physical-table-map-json>
create_or_update_dataset() {
  local id="$1" name="$2" ptm="$3"
  if aws quicksight describe-data-set --aws-account-id "${ACCOUNT_ID}" --data-set-id "${id}" \
       --region "${REGION}" >/dev/null 2>&1; then
    echo "  updating ${id}"
    aws quicksight update-data-set \
      --aws-account-id "${ACCOUNT_ID}" --data-set-id "${id}" --name "${name}" \
      --import-mode "DIRECT_QUERY" --physical-table-map "${ptm}" \
      --region "${REGION}" >/dev/null
  else
    echo "  creating ${id}"
    aws quicksight create-data-set \
      --aws-account-id "${ACCOUNT_ID}" --data-set-id "${id}" --name "${name}" \
      --import-mode "DIRECT_QUERY" --physical-table-map "${ptm}" \
      --permissions "${DATASET_PERMS}" --tags "${TAGS}" \
      --region "${REGION}" >/dev/null
  fi
}

# ============================================
# 1. Athena data source
# ============================================
# The workgroup is created by dashboard-stack.yaml and pins query results to the
# solution's own results bucket. Do NOT use "primary" -- in an account where Athena
# has never been used, primary has no output location and every query fails.
WORKGROUP="devops-agent-${ACCOUNT_ID}"

if ! aws athena get-work-group --work-group "${WORKGROUP}" --region "${REGION}" >/dev/null 2>&1; then
  echo "ERROR: Athena workgroup ${WORKGROUP} not found."
  echo "Deploy source/dashboard-account/dashboard-stack.yaml first (Step 1)."
  exit 1
fi

echo "Creating Athena data source (workgroup: ${WORKGROUP})..."
if aws quicksight describe-data-source --aws-account-id "${ACCOUNT_ID}" --data-source-id "${DS_ID}" \
     --region "${REGION}" >/dev/null 2>&1; then
  echo "  (data source already exists)"
else
  aws quicksight create-data-source \
    --aws-account-id "${ACCOUNT_ID}" --data-source-id "${DS_ID}" \
    --name "DevOps Agent Athena" --type "ATHENA" \
    --data-source-parameters "{\"AthenaParameters\":{\"WorkGroup\":\"${WORKGROUP}\"}}" \
    --permissions "${SOURCE_PERMS}" --tags "${TAGS}" \
    --region "${REGION}" >/dev/null
fi

# ============================================
# 2. Require the Glue table
# ============================================
echo "Checking if Glue table exists..."
if ! aws glue get-table --database-name "${GLUE_DB}" --name "${TABLE}" --region "${REGION}" >/dev/null 2>&1; then
  echo "WARNING: Table ${GLUE_DB}.${TABLE} does not exist yet."
  echo "The crawler needs at least one object in the centralized bucket to infer a schema."
  echo "  aws glue start-crawler --name devops-agent-crawler-${ACCOUNT_ID} --region ${REGION}"
  echo "Then re-run this script."
  exit 1
fi

# ============================================
# 3. Datasets
# ============================================
# Column names are lowercase because the Glue crawler lowercases the JSON keys
# written by the collector.
V2_COLS='[{"Name":"executionid","Type":"STRING"},{"Name":"workloadname","Type":"STRING"},{"Name":"accountid","Type":"STRING"},{"Name":"status","Type":"STRING"},{"Name":"priority","Type":"STRING"},{"Name":"durationminutes","Type":"DECIMAL"},{"Name":"investigationdate","Type":"STRING"},{"Name":"investigationmonth","Type":"STRING"},{"Name":"resolved","Type":"STRING"},{"Name":"rootcause","Type":"STRING"},{"Name":"rootcausedescription","Type":"STRING"},{"Name":"symptomcount","Type":"INTEGER"},{"Name":"causecount","Type":"INTEGER"},{"Name":"gapcount","Type":"INTEGER"},{"Name":"resourcecount","Type":"INTEGER"},{"Name":"contextwindowutilization","Type":"DECIMAL"},{"Name":"compactioncount","Type":"INTEGER"},{"Name":"totaltoolcalls","Type":"INTEGER"},{"Name":"subagentcount","Type":"INTEGER"},{"Name":"agentcostusd","Type":"DECIMAL"},{"Name":"consoleurl","Type":"STRING"},{"Name":"investigationstartedat","Type":"STRING"},{"Name":"investigationcompletedat","Type":"STRING"}]'

# consoleurl drives the "Open" link column on the Investigations sheet; the two
# timestamps are carried so the raw investigation window is visible in a drill-down.
V2_SQL="SELECT executionid, workloadname, accountid, status, priority, durationminutes, investigationdate, investigationmonth, CAST(resolved AS VARCHAR) as resolved, rootcause, rootcausedescription, symptomcount, causecount, gapcount, resourcecount, contextwindowutilization, compactioncount, totaltoolcalls, subagentcount, agentcostusd, consoleurl, investigationstartedat, investigationcompletedat FROM ${GLUE_DB}.${TABLE}"

echo "Datasets:"
create_or_update_dataset "devops-agent-v2" "DevOps Agent - Investigations" \
  "{\"v2-table\":{\"CustomSql\":{\"DataSourceArn\":\"${DS_ARN}\",\"Name\":\"v2_table\",\"SqlQuery\":\"${V2_SQL}\",\"Columns\":${V2_COLS}}}}"

RES_SQL="SELECT executionid, workloadname, accountid, investigationmonth, r AS resource FROM ${GLUE_DB}.${TABLE} CROSS JOIN UNNEST(relatedresources) AS t(r)"
RES_COLS='[{"Name":"executionid","Type":"STRING"},{"Name":"workloadname","Type":"STRING"},{"Name":"accountid","Type":"STRING"},{"Name":"investigationmonth","Type":"STRING"},{"Name":"resource","Type":"STRING"}]'

create_or_update_dataset "devops-agent-v2-resources" "DevOps Agent - Resources" \
  "{\"res-table\":{\"CustomSql\":{\"DataSourceArn\":\"${DS_ARN}\",\"Name\":\"resources\",\"SqlQuery\":\"${RES_SQL}\",\"Columns\":${RES_COLS}}}}"

# One row per finding, with the finding kind in recordtype. The numeric prefix is
# deliberate: it sorts the cascade in reading order (root cause first, then the
# contributing causes, symptoms, gaps, and finally the resources the agent looked at).
# '5_resource' unnests the same relatedresources array as the resources dataset, so
# the Investigations sheet can show every finding for one execution in a single pivot
# instead of a separate panel per finding kind.
DETAILS_SQL="SELECT executionid, workloadname, accountid, investigationmonth, '1_root_cause' AS recordtype, rootcause AS title FROM ${GLUE_DB}.${TABLE} WHERE rootcause != '' UNION ALL SELECT executionid, workloadname, accountid, investigationmonth, '2_cause' AS recordtype, c AS title FROM ${GLUE_DB}.${TABLE} CROSS JOIN UNNEST(causes) AS t(c) UNION ALL SELECT executionid, workloadname, accountid, investigationmonth, '3_symptom' AS recordtype, s AS title FROM ${GLUE_DB}.${TABLE} CROSS JOIN UNNEST(symptoms) AS t(s) UNION ALL SELECT executionid, workloadname, accountid, investigationmonth, '4_gap' AS recordtype, g AS title FROM ${GLUE_DB}.${TABLE} CROSS JOIN UNNEST(gaps) AS t(g) UNION ALL SELECT executionid, workloadname, accountid, investigationmonth, '5_resource' AS recordtype, r AS title FROM ${GLUE_DB}.${TABLE} CROSS JOIN UNNEST(relatedresources) AS t(r)"
DETAILS_COLS='[{"Name":"executionid","Type":"STRING"},{"Name":"workloadname","Type":"STRING"},{"Name":"accountid","Type":"STRING"},{"Name":"investigationmonth","Type":"STRING"},{"Name":"recordtype","Type":"STRING"},{"Name":"title","Type":"STRING"}]'

create_or_update_dataset "devops-agent-v2-details" "DevOps Agent - Details" \
  "{\"det-table\":{\"CustomSql\":{\"DataSourceArn\":\"${DS_ARN}\",\"Name\":\"details\",\"SqlQuery\":\"${DETAILS_SQL}\",\"Columns\":${DETAILS_COLS}}}}"

# The recommendations table only exists once the recommendation collector has run at
# least once (weekly schedule, or scripts/backfill-recommendations.sh on demand).
# Its dataset is skipped rather than failing the whole setup.
if aws glue get-table --database-name "${GLUE_DB}" --name "${REC_TABLE}" --region "${REGION}" >/dev/null 2>&1; then
  # recommendationid != 'none' filters the placeholder row the collector writes for an
  # AgentSpace that currently has no recommendations.
  REC_SQL="SELECT account_id, agentspace_id, workloadname, collected_at, recommendationid, title, status, priority, taskid FROM ${GLUE_DB}.${REC_TABLE} WHERE recommendationid != 'none'"
  REC_COLS='[{"Name":"account_id","Type":"STRING"},{"Name":"agentspace_id","Type":"STRING"},{"Name":"workloadname","Type":"STRING"},{"Name":"collected_at","Type":"STRING"},{"Name":"recommendationid","Type":"STRING"},{"Name":"title","Type":"STRING"},{"Name":"status","Type":"STRING"},{"Name":"priority","Type":"STRING"},{"Name":"taskid","Type":"STRING"}]'

  create_or_update_dataset "devops-agent-v2-recommendations" "DevOps Agent - Recommendations" \
    "{\"rec-table\":{\"CustomSql\":{\"DataSourceArn\":\"${DS_ARN}\",\"Name\":\"recommendations\",\"SqlQuery\":\"${REC_SQL}\",\"Columns\":${REC_COLS}}}}"
else
  echo "  SKIP devops-agent-v2-recommendations - table ${GLUE_DB}.${REC_TABLE} not found."
  echo "       Run scripts/backfill-recommendations.sh in a workload account, then the"
  echo "       crawler, then re-run this script. The Cost & Recommendations sheet needs it."
fi

# ============================================
# 4. Analysis
# ============================================
echo "Applying analysis definition..."
DEFINITION_FILE="$(dirname "$0")/dashboard-definition.json"
if [ ! -f "${DEFINITION_FILE}" ]; then
  echo "ERROR: ${DEFINITION_FILE} not found"
  exit 1
fi

TEMP_DEF=$(mktemp)
trap 'rm -f "${TEMP_DEF}"' EXIT
sed "s/{ACCOUNT_ID}/${ACCOUNT_ID}/g; s/{REGION}/${REGION}/g" "${DEFINITION_FILE}" > "${TEMP_DEF}"

if aws quicksight describe-analysis --aws-account-id "${ACCOUNT_ID}" --analysis-id "${ANALYSIS_ID}" \
     --region "${REGION}" >/dev/null 2>&1; then
  echo "  updating analysis ${ANALYSIS_ID}"
  aws quicksight update-analysis \
    --aws-account-id "${ACCOUNT_ID}" --analysis-id "${ANALYSIS_ID}" --name "${ANALYSIS_NAME}" \
    --definition "file://${TEMP_DEF}" --region "${REGION}" >/dev/null
else
  echo "  creating analysis ${ANALYSIS_ID}"
  aws quicksight create-analysis \
    --aws-account-id "${ACCOUNT_ID}" --analysis-id "${ANALYSIS_ID}" --name "${ANALYSIS_NAME}" \
    --definition "file://${TEMP_DEF}" --permissions "${ANALYSIS_PERMS}" --tags "${TAGS}" \
    --region "${REGION}" >/dev/null
fi

# The analysis is created asynchronously. A definition error surfaces here, not above.
echo "Waiting for the analysis to settle..."
for _ in $(seq 1 30); do
  STATUS=$(aws quicksight describe-analysis --aws-account-id "${ACCOUNT_ID}" \
    --analysis-id "${ANALYSIS_ID}" --region "${REGION}" --query 'Analysis.Status' --output text)
  case "${STATUS}" in
    CREATION_SUCCESSFUL|UPDATE_SUCCESSFUL) break ;;
    CREATION_FAILED|UPDATE_FAILED)
      echo "ERROR: analysis ${STATUS}"
      aws quicksight describe-analysis --aws-account-id "${ACCOUNT_ID}" \
        --analysis-id "${ANALYSIS_ID}" --region "${REGION}" --query 'Analysis.Errors'
      exit 1 ;;
  esac
  sleep 2
done
echo "  analysis status: ${STATUS}"

echo ""
echo "=== Setup Complete ==="
echo "Open the analysis: https://${REGION}.quicksight.aws.amazon.com/sn/analyses/${ANALYSIS_ID}"
echo ""
echo "Next steps:"
echo "  1. Confirm data appears on all four sheets."
echo "  2. Publish for read-only viewers: QuickSight -> Share -> Publish dashboard."
echo "     An analysis is only visible to authors; readers need a published dashboard."
