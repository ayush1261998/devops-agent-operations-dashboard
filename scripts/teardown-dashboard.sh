#!/bin/bash
# teardown-dashboard.sh — Removes QuickSight resources
# Usage: ./teardown-dashboard.sh <ACCOUNT_ID> <REGION>
set -euo pipefail

ACCOUNT_ID="${1:?Usage: teardown-dashboard.sh <ACCOUNT_ID> <REGION>}"
REGION="${2:-us-east-1}"

echo "=== DevOps Agent Dashboard Teardown ==="
echo "Account: ${ACCOUNT_ID}"
echo "Region:  ${REGION}"
echo ""
read -p "This will delete the QuickSight analysis and datasets. Continue? (y/N) " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || exit 0

echo "Deleting analysis..."
aws quicksight delete-analysis --aws-account-id "${ACCOUNT_ID}" --analysis-id "devops-agent-operations-dashboard" --region "${REGION}" 2>/dev/null || echo "  (not found)"

echo "Deleting datasets..."
aws quicksight delete-data-set --aws-account-id "${ACCOUNT_ID}" --data-set-id "devops-agent-v2" --region "${REGION}" 2>/dev/null || echo "  (not found)"
aws quicksight delete-data-set --aws-account-id "${ACCOUNT_ID}" --data-set-id "devops-agent-v2-resources" --region "${REGION}" 2>/dev/null || echo "  (not found)"
aws quicksight delete-data-set --aws-account-id "${ACCOUNT_ID}" --data-set-id "devops-agent-v2-details" --region "${REGION}" 2>/dev/null || echo "  (not found)"

echo "Deleting data source..."
aws quicksight delete-data-source --aws-account-id "${ACCOUNT_ID}" --data-source-id "devops-agent-athena-ds" --region "${REGION}" 2>/dev/null || echo "  (not found)"

echo ""
echo "=== Teardown Complete ==="
echo "CloudFormation stacks and S3 data are NOT removed."
echo "Run 'aws cloudformation delete-stack' separately if needed."
