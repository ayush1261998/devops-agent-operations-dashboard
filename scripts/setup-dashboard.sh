#!/bin/bash
# setup-dashboard.sh — Creates QuickSight data source, datasets, and analysis
# Usage: ./setup-dashboard.sh <ACCOUNT_ID> <REGION>
set -euo pipefail

ACCOUNT_ID="${1:?Usage: setup-dashboard.sh <ACCOUNT_ID> <REGION>}"
REGION="${2:-us-east-1}"
GLUE_DB="devops_agent_dashboard"

echo "=== DevOps Agent Dashboard Setup ==="
echo "Account: ${ACCOUNT_ID}"
echo "Region:  ${REGION}"

# Get QuickSight identity (user ARN)
QS_USER=$(aws quicksight list-users --aws-account-id "${ACCOUNT_ID}" --namespace default --region "${REGION}" --query 'UserList[0].Arn' --output text)
echo "QuickSight User: ${QS_USER}"

# ============================================
# 1. Create Athena Data Source
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
aws quicksight create-data-source \
  --aws-account-id "${ACCOUNT_ID}" \
  --data-source-id "devops-agent-athena-ds" \
  --name "DevOps Agent Athena" \
  --type "ATHENA" \
  --data-source-parameters "{\"AthenaParameters\":{\"WorkGroup\":\"${WORKGROUP}\"}}" \
  --permissions "[{\"Principal\":\"${QS_USER}\",\"Actions\":[\"quicksight:DescribeDataSource\",\"quicksight:DescribeDataSourcePermissions\",\"quicksight:PassDataSource\",\"quicksight:UpdateDataSource\",\"quicksight:DeleteDataSource\",\"quicksight:UpdateDataSourcePermissions\"]}]" \
  --region "${REGION}" 2>/dev/null || echo "  (data source already exists)"

DS_ARN="arn:aws:quicksight:${REGION}:${ACCOUNT_ID}:datasource/devops-agent-athena-ds"

# ============================================
# 2. Wait for Glue crawler to have data
# ============================================
echo "Checking if Glue table exists..."
TABLE_EXISTS=$(aws glue get-table --database-name "${GLUE_DB}" --name "investigations_v2" --region "${REGION}" 2>/dev/null && echo "yes" || echo "no")
if [ "${TABLE_EXISTS}" = "no" ]; then
  echo "WARNING: Table ${GLUE_DB}.investigations_v2 does not exist yet."
  echo "Run the Glue crawler first: aws glue start-crawler --name devops-agent-crawler-${ACCOUNT_ID}"
  echo "Then re-run this script."
  exit 1
fi

# ============================================
# 3. Create Main Dataset
# ============================================
echo "Creating main dataset..."
aws quicksight create-data-set \
  --aws-account-id "${ACCOUNT_ID}" \
  --data-set-id "devops-agent-v2" \
  --name "DevOps Agent - Investigations" \
  --import-mode "DIRECT_QUERY" \
  --physical-table-map "{\"v2-table\":{\"CustomSql\":{\"DataSourceArn\":\"${DS_ARN}\",\"Name\":\"v2_table\",\"SqlQuery\":\"SELECT executionid, workloadname, accountid, status, priority, durationminutes, investigationdate, investigationmonth, CAST(resolved AS VARCHAR) as resolved, rootcause, rootcausedescription, symptomcount, causecount, gapcount, resourcecount, contextwindowutilization, compactioncount, totaltoolcalls, subagentcount, agentcostusd FROM ${GLUE_DB}.investigations_v2\",\"Columns\":[{\"Name\":\"executionid\",\"Type\":\"STRING\"},{\"Name\":\"workloadname\",\"Type\":\"STRING\"},{\"Name\":\"accountid\",\"Type\":\"STRING\"},{\"Name\":\"status\",\"Type\":\"STRING\"},{\"Name\":\"priority\",\"Type\":\"STRING\"},{\"Name\":\"durationminutes\",\"Type\":\"DECIMAL\"},{\"Name\":\"investigationdate\",\"Type\":\"STRING\"},{\"Name\":\"investigationmonth\",\"Type\":\"STRING\"},{\"Name\":\"resolved\",\"Type\":\"STRING\"},{\"Name\":\"rootcause\",\"Type\":\"STRING\"},{\"Name\":\"rootcausedescription\",\"Type\":\"STRING\"},{\"Name\":\"symptomcount\",\"Type\":\"INTEGER\"},{\"Name\":\"causecount\",\"Type\":\"INTEGER\"},{\"Name\":\"gapcount\",\"Type\":\"INTEGER\"},{\"Name\":\"resourcecount\",\"Type\":\"INTEGER\"},{\"Name\":\"contextwindowutilization\",\"Type\":\"DECIMAL\"},{\"Name\":\"compactioncount\",\"Type\":\"INTEGER\"},{\"Name\":\"totaltoolcalls\",\"Type\":\"INTEGER\"},{\"Name\":\"subagentcount\",\"Type\":\"INTEGER\"},{\"Name\":\"agentcostusd\",\"Type\":\"DECIMAL\"}]}}}" \
  --permissions "[{\"Principal\":\"${QS_USER}\",\"Actions\":[\"quicksight:DescribeDataSet\",\"quicksight:DescribeDataSetPermissions\",\"quicksight:PassDataSet\",\"quicksight:DescribeIngestion\",\"quicksight:ListIngestions\",\"quicksight:UpdateDataSet\",\"quicksight:DeleteDataSet\",\"quicksight:CreateIngestion\",\"quicksight:CancelIngestion\",\"quicksight:UpdateDataSetPermissions\"]}]" \
  --region "${REGION}" 2>/dev/null || echo "  (dataset already exists, updating...)" && \
  aws quicksight update-data-set \
    --aws-account-id "${ACCOUNT_ID}" \
    --data-set-id "devops-agent-v2" \
    --name "DevOps Agent - Investigations" \
    --import-mode "DIRECT_QUERY" \
    --physical-table-map "{\"v2-table\":{\"CustomSql\":{\"DataSourceArn\":\"${DS_ARN}\",\"Name\":\"v2_table\",\"SqlQuery\":\"SELECT executionid, workloadname, accountid, status, priority, durationminutes, investigationdate, investigationmonth, CAST(resolved AS VARCHAR) as resolved, rootcause, rootcausedescription, symptomcount, causecount, gapcount, resourcecount, contextwindowutilization, compactioncount, totaltoolcalls, subagentcount, agentcostusd FROM ${GLUE_DB}.investigations_v2\",\"Columns\":[{\"Name\":\"executionid\",\"Type\":\"STRING\"},{\"Name\":\"workloadname\",\"Type\":\"STRING\"},{\"Name\":\"accountid\",\"Type\":\"STRING\"},{\"Name\":\"status\",\"Type\":\"STRING\"},{\"Name\":\"priority\",\"Type\":\"STRING\"},{\"Name\":\"durationminutes\",\"Type\":\"DECIMAL\"},{\"Name\":\"investigationdate\",\"Type\":\"STRING\"},{\"Name\":\"investigationmonth\",\"Type\":\"STRING\"},{\"Name\":\"resolved\",\"Type\":\"STRING\"},{\"Name\":\"rootcause\",\"Type\":\"STRING\"},{\"Name\":\"rootcausedescription\",\"Type\":\"STRING\"},{\"Name\":\"symptomcount\",\"Type\":\"INTEGER\"},{\"Name\":\"causecount\",\"Type\":\"INTEGER\"},{\"Name\":\"gapcount\",\"Type\":\"INTEGER\"},{\"Name\":\"resourcecount\",\"Type\":\"INTEGER\"},{\"Name\":\"contextwindowutilization\",\"Type\":\"DECIMAL\"},{\"Name\":\"compactioncount\",\"Type\":\"INTEGER\"},{\"Name\":\"totaltoolcalls\",\"Type\":\"INTEGER\"},{\"Name\":\"subagentcount\",\"Type\":\"INTEGER\"},{\"Name\":\"agentcostusd\",\"Type\":\"DECIMAL\"}]}}}" \
    --region "${REGION}" 2>/dev/null

# ============================================
# 4. Create Resources Dataset (UNNEST)
# ============================================
echo "Creating resources dataset..."
aws quicksight create-data-set \
  --aws-account-id "${ACCOUNT_ID}" \
  --data-set-id "devops-agent-v2-resources" \
  --name "DevOps Agent - Resources" \
  --import-mode "DIRECT_QUERY" \
  --physical-table-map "{\"res-table\":{\"CustomSql\":{\"DataSourceArn\":\"${DS_ARN}\",\"Name\":\"resources\",\"SqlQuery\":\"SELECT executionid, workloadname, accountid, investigationmonth, r AS resource FROM ${GLUE_DB}.investigations_v2 CROSS JOIN UNNEST(relatedresources) AS t(r)\",\"Columns\":[{\"Name\":\"executionid\",\"Type\":\"STRING\"},{\"Name\":\"workloadname\",\"Type\":\"STRING\"},{\"Name\":\"accountid\",\"Type\":\"STRING\"},{\"Name\":\"investigationmonth\",\"Type\":\"STRING\"},{\"Name\":\"resource\",\"Type\":\"STRING\"}]}}}" \
  --permissions "[{\"Principal\":\"${QS_USER}\",\"Actions\":[\"quicksight:DescribeDataSet\",\"quicksight:DescribeDataSetPermissions\",\"quicksight:PassDataSet\",\"quicksight:DescribeIngestion\",\"quicksight:ListIngestions\",\"quicksight:UpdateDataSet\",\"quicksight:DeleteDataSet\",\"quicksight:CreateIngestion\",\"quicksight:CancelIngestion\",\"quicksight:UpdateDataSetPermissions\"]}]" \
  --region "${REGION}" 2>/dev/null || echo "  (resources dataset already exists)"

# ============================================
# 5. Create Details Dataset (UNION of findings)
# ============================================
echo "Creating details dataset..."
DETAILS_SQL="SELECT executionid, workloadname, accountid, investigationmonth, '1_root_cause' AS recordtype, rootcause AS title FROM ${GLUE_DB}.investigations_v2 WHERE rootcause != '' UNION ALL SELECT executionid, workloadname, accountid, investigationmonth, '2_cause' AS recordtype, c AS title FROM ${GLUE_DB}.investigations_v2 CROSS JOIN UNNEST(causes) AS t(c) UNION ALL SELECT executionid, workloadname, accountid, investigationmonth, '3_symptom' AS recordtype, s AS title FROM ${GLUE_DB}.investigations_v2 CROSS JOIN UNNEST(symptoms) AS t(s) UNION ALL SELECT executionid, workloadname, accountid, investigationmonth, '4_gap' AS recordtype, g AS title FROM ${GLUE_DB}.investigations_v2 CROSS JOIN UNNEST(gaps) AS t(g)"

aws quicksight create-data-set \
  --aws-account-id "${ACCOUNT_ID}" \
  --data-set-id "devops-agent-v2-details" \
  --name "DevOps Agent - Details" \
  --import-mode "DIRECT_QUERY" \
  --physical-table-map "{\"det-table\":{\"CustomSql\":{\"DataSourceArn\":\"${DS_ARN}\",\"Name\":\"details\",\"SqlQuery\":\"${DETAILS_SQL}\",\"Columns\":[{\"Name\":\"executionid\",\"Type\":\"STRING\"},{\"Name\":\"workloadname\",\"Type\":\"STRING\"},{\"Name\":\"accountid\",\"Type\":\"STRING\"},{\"Name\":\"investigationmonth\",\"Type\":\"STRING\"},{\"Name\":\"recordtype\",\"Type\":\"STRING\"},{\"Name\":\"title\",\"Type\":\"STRING\"}]}}}" \
  --permissions "[{\"Principal\":\"${QS_USER}\",\"Actions\":[\"quicksight:DescribeDataSet\",\"quicksight:DescribeDataSetPermissions\",\"quicksight:PassDataSet\",\"quicksight:DescribeIngestion\",\"quicksight:ListIngestions\",\"quicksight:UpdateDataSet\",\"quicksight:DeleteDataSet\",\"quicksight:CreateIngestion\",\"quicksight:CancelIngestion\",\"quicksight:UpdateDataSetPermissions\"]}]" \
  --region "${REGION}" 2>/dev/null || echo "  (details dataset already exists)"

# ============================================
# 6. Apply Dashboard Definition
# ============================================
echo "Creating analysis from definition..."
DEFINITION_FILE="$(dirname "$0")/dashboard-definition.json"

if [ ! -f "${DEFINITION_FILE}" ]; then
  echo "ERROR: ${DEFINITION_FILE} not found"
  echo "Export it from a working dashboard or use the provided template."
  exit 1
fi

# Replace placeholders
TEMP_DEF="/tmp/qs-def-${ACCOUNT_ID}.json"
sed "s/{ACCOUNT_ID}/${ACCOUNT_ID}/g; s/{REGION}/${REGION}/g" "${DEFINITION_FILE}" > "${TEMP_DEF}"

aws quicksight create-analysis \
  --aws-account-id "${ACCOUNT_ID}" \
  --analysis-id "devops-agent-operations-dashboard" \
  --name "DevOps Agent - Operations Dashboard" \
  --definition "file://${TEMP_DEF}" \
  --permissions "[{\"Principal\":\"${QS_USER}\",\"Actions\":[\"quicksight:RestoreAnalysis\",\"quicksight:UpdateAnalysisPermissions\",\"quicksight:DeleteAnalysis\",\"quicksight:DescribeAnalysisPermissions\",\"quicksight:QueryAnalysis\",\"quicksight:DescribeAnalysis\",\"quicksight:UpdateAnalysis\"]}]" \
  --region "${REGION}" 2>/dev/null || \
  aws quicksight update-analysis \
    --aws-account-id "${ACCOUNT_ID}" \
    --analysis-id "devops-agent-operations-dashboard" \
    --name "DevOps Agent - Operations Dashboard" \
    --definition "file://${TEMP_DEF}" \
    --region "${REGION}"

rm -f "${TEMP_DEF}"

echo ""
echo "=== Setup Complete ==="
echo "Open QuickSight: https://${REGION}.quicksight.aws.amazon.com/sn/analyses/devops-agent-operations-dashboard"
echo ""
echo "Next steps:"
echo "  1. Add text descriptions to each sheet (Add → Text in QuickSight UI)"
echo "  2. Trigger an investigation to verify end-to-end flow"
echo "  3. Publish as dashboard for readers: QuickSight → Share → Publish dashboard"
