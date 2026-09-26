#!/bin/bash
# teardown-dashboard.sh — Removes the QuickSight resources created by setup-dashboard.sh.
# Usage: ./teardown-dashboard.sh <ACCOUNT_ID> <REGION>
#
# This removes QuickSight objects only. CloudFormation stacks and S3 data are left
# alone -- see the Cleanup section of the README for those (the buckets are versioned
# and must be purged before their stacks can be deleted).
set -euo pipefail

ACCOUNT_ID="${1:?Usage: teardown-dashboard.sh <ACCOUNT_ID> <REGION>}"
REGION="${2:-us-east-1}"

echo "=== DevOps Agent Dashboard Teardown ==="
echo "Account: ${ACCOUNT_ID}"
echo "Region:  ${REGION}"
echo ""
read -p "This will delete the QuickSight analysis, datasets, and data source. Continue? (y/N) " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || exit 0

# A published dashboard is a separate object from the analysis it came from, so it has
# to be deleted separately. Deleting only the analysis leaves readers with a dashboard
# whose datasets have been removed -- every visual then errors instead of disappearing.
echo "Deleting published dashboard (if one exists)..."
aws quicksight delete-dashboard --aws-account-id "${ACCOUNT_ID}" \
  --dashboard-id "devops-agent-operations-dashboard" --region "${REGION}" 2>/dev/null \
  || echo "  (not found)"

echo "Deleting analysis..."
aws quicksight delete-analysis --aws-account-id "${ACCOUNT_ID}" \
  --analysis-id "devops-agent-operations-dashboard" \
  --force-delete-without-recovery --region "${REGION}" 2>/dev/null || echo "  (not found)"

echo "Deleting datasets..."
for DS in devops-agent-v2 devops-agent-v2-resources devops-agent-v2-details devops-agent-v2-recommendations; do
  aws quicksight delete-data-set --aws-account-id "${ACCOUNT_ID}" --data-set-id "${DS}" \
    --region "${REGION}" >/dev/null 2>&1 && echo "  deleted ${DS}" || echo "  (${DS} not found)"
done

echo "Deleting data source..."
aws quicksight delete-data-source --aws-account-id "${ACCOUNT_ID}" \
  --data-source-id "devops-agent-athena-ds" --region "${REGION}" >/dev/null 2>&1 \
  && echo "  deleted devops-agent-athena-ds" || echo "  (not found)"

echo ""
echo "=== Teardown Complete ==="
echo "CloudFormation stacks and S3 data are NOT removed."
echo "See the Cleanup section of the README -- both buckets are versioned and must be"
echo "purged before their stacks will delete."
