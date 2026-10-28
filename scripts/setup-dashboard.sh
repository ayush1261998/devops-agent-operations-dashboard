#!/bin/bash
# setup-dashboard.sh - Creates or updates the QuickSight data source, datasets,
# analysis, and published dashboard. Run in the dashboard account, in the
# analytics Region, after dashboard-stack.yaml is deployed.
#
# Usage: ./setup-dashboard.sh <DASHBOARD_ACCOUNT_ID> <ANALYTICS_REGION>
#
# Idempotent: every resource is created if absent and updated in place if
# present, so re-running always converges on the definitions in this repo.
# It works before any data exists - the Glue tables come from the stack.
set -euo pipefail

ACCOUNT_ID="${1:?Usage: setup-dashboard.sh <DASHBOARD_ACCOUNT_ID> <ANALYTICS_REGION>}"
REGION="${2:?Usage: setup-dashboard.sh <DASHBOARD_ACCOUNT_ID> <ANALYTICS_REGION>}"
GLUE_DB="devops_agent_dashboard"
DASH_ID="devops-agent-operations-dashboard"
DASH_NAME="DevOps Agent - Operations Dashboard"
WORKGROUP="devops-agent-${ACCOUNT_ID}"

echo "=== DevOps Agent Dashboard Setup ==="
echo "Account: ${ACCOUNT_ID}   Region: ${REGION}"

# The QuickSight identity that will own every resource.
QS_USER=$(aws quicksight list-users --aws-account-id "${ACCOUNT_ID}" --namespace default \
  --region "${REGION}" --query 'UserList[0].Arn' --output text)
if [ -z "${QS_USER}" ] || [ "${QS_USER}" = "None" ]; then
  echo "ERROR: no QuickSight user in ${ACCOUNT_ID}/${REGION}. Enable QuickSight Enterprise first." >&2
  exit 1
fi
echo "QuickSight owner: ${QS_USER}"

if ! aws athena get-work-group --work-group "${WORKGROUP}" --region "${REGION}" >/dev/null 2>&1; then
  echo "ERROR: Athena workgroup ${WORKGROUP} not found. Deploy dashboard-stack.yaml first." >&2
  exit 1
fi
for T in investigations_v2 recommendations_v1 collector_status; do
  if ! aws glue get-table --database-name "${GLUE_DB}" --name "${T}" --region "${REGION}" >/dev/null 2>&1; then
    echo "ERROR: Glue table ${GLUE_DB}.${T} not found. Deploy or update dashboard-stack.yaml." >&2
    exit 1
  fi
done

DS_ID="devops-agent-athena-ds"
DS_ARN="arn:aws:quicksight:${REGION}:${ACCOUNT_ID}:datasource/${DS_ID}"
TAGS='[{"Key":"Project","Value":"devops-agent-dashboard"}]'
SOURCE_PERMS="[{\"Principal\":\"${QS_USER}\",\"Actions\":[\"quicksight:DescribeDataSource\",\"quicksight:DescribeDataSourcePermissions\",\"quicksight:PassDataSource\",\"quicksight:UpdateDataSource\",\"quicksight:DeleteDataSource\",\"quicksight:UpdateDataSourcePermissions\"]}]"
DATASET_PERMS="[{\"Principal\":\"${QS_USER}\",\"Actions\":[\"quicksight:DescribeDataSet\",\"quicksight:DescribeDataSetPermissions\",\"quicksight:PassDataSet\",\"quicksight:DescribeIngestion\",\"quicksight:ListIngestions\",\"quicksight:UpdateDataSet\",\"quicksight:DeleteDataSet\",\"quicksight:CreateIngestion\",\"quicksight:CancelIngestion\",\"quicksight:UpdateDataSetPermissions\"]}]"
ANALYSIS_PERMS="[{\"Principal\":\"${QS_USER}\",\"Actions\":[\"quicksight:RestoreAnalysis\",\"quicksight:UpdateAnalysisPermissions\",\"quicksight:DeleteAnalysis\",\"quicksight:DescribeAnalysisPermissions\",\"quicksight:QueryAnalysis\",\"quicksight:DescribeAnalysis\",\"quicksight:UpdateAnalysis\"]}]"
DASH_PERMS="[{\"Principal\":\"${QS_USER}\",\"Actions\":[\"quicksight:DescribeDashboard\",\"quicksight:ListDashboardVersions\",\"quicksight:UpdateDashboardPermissions\",\"quicksight:QueryDashboard\",\"quicksight:UpdateDashboard\",\"quicksight:DeleteDashboard\",\"quicksight:DescribeDashboardPermissions\",\"quicksight:UpdateDashboardPublishedVersion\"]}]"

# create_or_update_dataset <id> <name> <physical-table-map-json>
create_or_update_dataset() {
  local id="$1" name="$2" ptm="$3"
  if aws quicksight describe-data-set --aws-account-id "${ACCOUNT_ID}" --data-set-id "${id}" \
       --region "${REGION}" >/dev/null 2>&1; then
    echo "  updating ${id}"
    aws quicksight update-data-set --aws-account-id "${ACCOUNT_ID}" --data-set-id "${id}" \
      --name "${name}" --import-mode DIRECT_QUERY --physical-table-map "${ptm}" \
      --region "${REGION}" >/dev/null
  else
    echo "  creating ${id}"
    aws quicksight create-data-set --aws-account-id "${ACCOUNT_ID}" --data-set-id "${id}" \
      --name "${name}" --import-mode DIRECT_QUERY --physical-table-map "${ptm}" \
      --permissions "${DATASET_PERMS}" --tags "${TAGS}" --region "${REGION}" >/dev/null
  fi
}

# custom_sql_ptm <table-key> <name> <sql> <columns-json>
custom_sql_ptm() {
  printf '{"%s":{"CustomSql":{"DataSourceArn":"%s","Name":"%s","SqlQuery":"%s","Columns":%s}}}' \
    "$1" "${DS_ARN}" "$2" "$3" "$4"
}

# 1. Athena data source on the solution workgroup.
echo "Data source:"
if aws quicksight describe-data-source --aws-account-id "${ACCOUNT_ID}" --data-source-id "${DS_ID}" \
     --region "${REGION}" >/dev/null 2>&1; then
  # Update in place so a re-run always converges on the current workgroup. A data
  # source left over from an earlier deploy can otherwise keep pointing at a
  # deleted workgroup, and every dataset built on it fails ("WorkGroup is not found").
  echo "  updating ${DS_ID}"
  aws quicksight update-data-source --aws-account-id "${ACCOUNT_ID}" --data-source-id "${DS_ID}" \
    --name "DevOps Agent Athena" \
    --data-source-parameters "{\"AthenaParameters\":{\"WorkGroup\":\"${WORKGROUP}\"}}" \
    --region "${REGION}" >/dev/null
else
  echo "  creating ${DS_ID}"
  aws quicksight create-data-source --aws-account-id "${ACCOUNT_ID}" --data-source-id "${DS_ID}" \
    --name "DevOps Agent Athena" --type ATHENA \
    --data-source-parameters "{\"AthenaParameters\":{\"WorkGroup\":\"${WORKGROUP}\"}}" \
    --permissions "${SOURCE_PERMS}" --tags "${TAGS}" --region "${REGION}" >/dev/null
fi

# 2. Datasets. Every dataset exposes `accountid` and `region` under the same
# names, so the shared Account and Region filters (CrossDataset: ALL_DATASETS)
# slice all of them. `region` is the Agent Space Region.
echo "Datasets:"
INV="${GLUE_DB}.investigations_v2"

# Investigation metrics are over COMPLETED investigations only. Failed and timed-out
# investigations are counted on the Coverage table instead.
V2_SQL="SELECT executionid, workloadname, accountid, agentspaceregion AS region, status, priority, durationminutes, investigationdate, investigationmonth, CAST(resolved AS VARCHAR) AS resolved, rootcause, rootcausedescription, symptomcount, causecount, gapcount, resourcecount, contextwindowutilization, compactioncount, totaltoolcalls, subagentcount, agentcostusd, consoleurl, investigationstartedat, investigationcompletedat FROM ${INV} WHERE status = 'COMPLETED'"
V2_COLS='[{"Name":"executionid","Type":"STRING"},{"Name":"workloadname","Type":"STRING"},{"Name":"accountid","Type":"STRING"},{"Name":"region","Type":"STRING"},{"Name":"status","Type":"STRING"},{"Name":"priority","Type":"STRING"},{"Name":"durationminutes","Type":"DECIMAL"},{"Name":"investigationdate","Type":"STRING"},{"Name":"investigationmonth","Type":"STRING"},{"Name":"resolved","Type":"STRING"},{"Name":"rootcause","Type":"STRING"},{"Name":"rootcausedescription","Type":"STRING"},{"Name":"symptomcount","Type":"INTEGER"},{"Name":"causecount","Type":"INTEGER"},{"Name":"gapcount","Type":"INTEGER"},{"Name":"resourcecount","Type":"INTEGER"},{"Name":"contextwindowutilization","Type":"DECIMAL"},{"Name":"compactioncount","Type":"INTEGER"},{"Name":"totaltoolcalls","Type":"INTEGER"},{"Name":"subagentcount","Type":"INTEGER"},{"Name":"agentcostusd","Type":"DECIMAL"},{"Name":"consoleurl","Type":"STRING"},{"Name":"investigationstartedat","Type":"STRING"},{"Name":"investigationcompletedat","Type":"STRING"}]'
create_or_update_dataset "devops-agent-v2" "DevOps Agent - Investigations" \
  "$(custom_sql_ptm v2-table v2_table "${V2_SQL}" "${V2_COLS}")"

RES_SQL="SELECT executionid, workloadname, accountid, agentspaceregion AS region, investigationmonth, r AS resource FROM ${INV} CROSS JOIN UNNEST(relatedresources) AS t(r) WHERE status = 'COMPLETED'"
RES_COLS='[{"Name":"executionid","Type":"STRING"},{"Name":"workloadname","Type":"STRING"},{"Name":"accountid","Type":"STRING"},{"Name":"region","Type":"STRING"},{"Name":"investigationmonth","Type":"STRING"},{"Name":"resource","Type":"STRING"}]'
create_or_update_dataset "devops-agent-v2-resources" "DevOps Agent - Resources" \
  "$(custom_sql_ptm res-table resources "${RES_SQL}" "${RES_COLS}")"

# One row per finding. The numeric prefix sorts the findings pivot in reading order.
D="SELECT executionid, workloadname, accountid, agentspaceregion AS region, investigationmonth"
W="WHERE status = 'COMPLETED'"
DETAILS_SQL="${D}, '1_root_cause' AS recordtype, rootcause AS title FROM ${INV} ${W} AND rootcause != '' UNION ALL ${D}, '2_cause' AS recordtype, c AS title FROM ${INV} CROSS JOIN UNNEST(causes) AS t(c) ${W} UNION ALL ${D}, '3_symptom' AS recordtype, s AS title FROM ${INV} CROSS JOIN UNNEST(symptoms) AS t(s) ${W} UNION ALL ${D}, '4_gap' AS recordtype, g AS title FROM ${INV} CROSS JOIN UNNEST(gaps) AS t(g) ${W} UNION ALL ${D}, '5_resource' AS recordtype, r AS title FROM ${INV} CROSS JOIN UNNEST(relatedresources) AS t(r) ${W}"
DETAILS_COLS='[{"Name":"executionid","Type":"STRING"},{"Name":"workloadname","Type":"STRING"},{"Name":"accountid","Type":"STRING"},{"Name":"region","Type":"STRING"},{"Name":"investigationmonth","Type":"STRING"},{"Name":"recordtype","Type":"STRING"},{"Name":"title","Type":"STRING"}]'
create_or_update_dataset "devops-agent-v2-details" "DevOps Agent - Details" \
  "$(custom_sql_ptm det-table details "${DETAILS_SQL}" "${DETAILS_COLS}")"

# recommendationid != 'none' drops the placeholder row written for an Agent Space
# that currently has no recommendations.
REC_SQL="SELECT accountid, agentspaceregion AS region, agentspaceid, workloadname, collected_at, recommendationid, title, status, priority, taskid FROM ${GLUE_DB}.recommendations_v1 WHERE recommendationid != 'none'"
REC_COLS='[{"Name":"accountid","Type":"STRING"},{"Name":"region","Type":"STRING"},{"Name":"agentspaceid","Type":"STRING"},{"Name":"workloadname","Type":"STRING"},{"Name":"collected_at","Type":"STRING"},{"Name":"recommendationid","Type":"STRING"},{"Name":"title","Type":"STRING"},{"Name":"status","Type":"STRING"},{"Name":"priority","Type":"STRING"},{"Name":"taskid","Type":"STRING"}]'
create_or_update_dataset "devops-agent-v2-recommendations" "DevOps Agent - Recommendations" \
  "$(custom_sql_ptm rec-table recommendations "${REC_SQL}" "${REC_COLS}")"

# Coverage: one row per collection stack, with health derived from its status
# record, plus the count of failed / timed-out investigations it recorded.
# A status record older than 5 days (two missed 2-day runs) is STALE.
COV_SQL="SELECT s.accountid, s.agentspaceregion AS region, CASE WHEN date_diff('day', from_iso8601_timestamp(s.lastrunat), current_timestamp) > 5 THEN 'STALE' ELSE s.status END AS health, s.status AS lastreportedstatus, s.agentspacecount, s.recommendationcount, s.lastrunat, date_diff('day', from_iso8601_timestamp(s.lastrunat), current_timestamp) AS dayssincelastrun, s.collectorversion, COALESCE(s.failedeventspending, 0) AS failedeventspending, COALESCE(s.replicationfailures, 0) AS replicationfailures, COALESCE(f.notcompleted, 0) AS failedortimedout, s.errormessage FROM ${GLUE_DB}.collector_status s LEFT JOIN (SELECT accountid, agentspaceregion, COUNT(*) AS notcompleted FROM ${INV} WHERE status IN ('FAILED', 'TIMED_OUT') GROUP BY accountid, agentspaceregion) f ON s.accountid = f.accountid AND s.agentspaceregion = f.agentspaceregion"
COV_COLS='[{"Name":"accountid","Type":"STRING"},{"Name":"region","Type":"STRING"},{"Name":"health","Type":"STRING"},{"Name":"lastreportedstatus","Type":"STRING"},{"Name":"agentspacecount","Type":"INTEGER"},{"Name":"recommendationcount","Type":"INTEGER"},{"Name":"lastrunat","Type":"STRING"},{"Name":"dayssincelastrun","Type":"INTEGER"},{"Name":"collectorversion","Type":"STRING"},{"Name":"failedeventspending","Type":"INTEGER"},{"Name":"replicationfailures","Type":"INTEGER"},{"Name":"failedortimedout","Type":"INTEGER"},{"Name":"errormessage","Type":"STRING"}]'
create_or_update_dataset "devops-agent-v2-coverage" "DevOps Agent - Coverage" \
  "$(custom_sql_ptm cov-table coverage "${COV_SQL}" "${COV_COLS}")"

# 3. Analysis and dashboard, both from scripts/dashboard-definition.json.
DEFINITION_FILE="$(dirname "$0")/dashboard-definition.json"
[ -f "${DEFINITION_FILE}" ] || { echo "ERROR: ${DEFINITION_FILE} not found" >&2; exit 1; }
TEMP_DEF=$(mktemp)
trap 'rm -f "${TEMP_DEF}"' EXIT
sed "s/{ACCOUNT_ID}/${ACCOUNT_ID}/g; s/{REGION}/${REGION}/g" "${DEFINITION_FILE}" > "${TEMP_DEF}"

# wait_for <describe-command> <id-flag> <id> <status-query>
wait_for() {
  local kind="$1" flag="$2" id="$3" query="$4" status=""
  for _ in $(seq 1 60); do
    status=$(aws quicksight "describe-${kind}" --aws-account-id "${ACCOUNT_ID}" "${flag}" "${id}" \
      --region "${REGION}" --query "${query}" --output text)
    case "${status}" in
      CREATION_SUCCESSFUL|UPDATE_SUCCESSFUL) echo "  ${kind} status: ${status}"; return 0 ;;
      CREATION_FAILED|UPDATE_FAILED)
        echo "ERROR: ${kind} ${status}" >&2
        aws quicksight "describe-${kind}" --aws-account-id "${ACCOUNT_ID}" "${flag}" "${id}" \
          --region "${REGION}" --query "${query%.Status}.Errors" >&2
        return 1 ;;
    esac
    sleep 2
  done
  echo "ERROR: ${kind} did not settle (last status: ${status})" >&2
  return 1
}

echo "Analysis:"
if aws quicksight describe-analysis --aws-account-id "${ACCOUNT_ID}" --analysis-id "${DASH_ID}" \
     --region "${REGION}" >/dev/null 2>&1; then
  echo "  updating ${DASH_ID}"
  aws quicksight update-analysis --aws-account-id "${ACCOUNT_ID}" --analysis-id "${DASH_ID}" \
    --name "${DASH_NAME}" --definition "file://${TEMP_DEF}" --region "${REGION}" >/dev/null
else
  echo "  creating ${DASH_ID}"
  aws quicksight create-analysis --aws-account-id "${ACCOUNT_ID}" --analysis-id "${DASH_ID}" \
    --name "${DASH_NAME}" --definition "file://${TEMP_DEF}" --permissions "${ANALYSIS_PERMS}" \
    --tags "${TAGS}" --region "${REGION}" >/dev/null
fi
wait_for analysis --analysis-id "${DASH_ID}" "Analysis.Status"

# A dashboard is what readers open. Updating one creates a new version that is not
# live until it is published, so publish the latest version explicitly.
echo "Dashboard:"
if aws quicksight describe-dashboard --aws-account-id "${ACCOUNT_ID}" --dashboard-id "${DASH_ID}" \
     --region "${REGION}" >/dev/null 2>&1; then
  echo "  updating ${DASH_ID}"
  aws quicksight update-dashboard --aws-account-id "${ACCOUNT_ID}" --dashboard-id "${DASH_ID}" \
    --name "${DASH_NAME}" --definition "file://${TEMP_DEF}" --region "${REGION}" >/dev/null
else
  echo "  creating ${DASH_ID}"
  aws quicksight create-dashboard --aws-account-id "${ACCOUNT_ID}" --dashboard-id "${DASH_ID}" \
    --name "${DASH_NAME}" --definition "file://${TEMP_DEF}" --permissions "${DASH_PERMS}" \
    --tags "${TAGS}" --region "${REGION}" >/dev/null
fi
wait_for dashboard --dashboard-id "${DASH_ID}" "Dashboard.Version.Status"
VERSION=$(aws quicksight describe-dashboard --aws-account-id "${ACCOUNT_ID}" --dashboard-id "${DASH_ID}" \
  --region "${REGION}" --query 'Dashboard.Version.VersionNumber' --output text)
aws quicksight update-dashboard-published-version --aws-account-id "${ACCOUNT_ID}" \
  --dashboard-id "${DASH_ID}" --version-number "${VERSION}" --region "${REGION}" >/dev/null
echo "  published version ${VERSION}"

echo ""
echo "=== Setup Complete ==="
echo "Dashboard: https://${REGION}.quicksight.aws.amazon.com/sn/dashboards/${DASH_ID}"
echo "Analysis:  https://${REGION}.quicksight.aws.amazon.com/sn/analyses/${DASH_ID}"
echo "Share the dashboard with readers from QuickSight (Share -> Share dashboard)."
