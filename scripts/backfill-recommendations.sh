#!/usr/bin/env bash
# ============================================
# Backfill Recommendations
# ============================================
# Invokes the recommendation collector Lambda once to populate current
# recommendations immediately, rather than waiting for the weekly schedule.
#
# Usage: ./backfill-recommendations.sh [REGION]
#
# Run this in each workload account AFTER deploying the collection stack.
# Safe to re-run — each invocation overwrites the same S3 keys.

set -euo pipefail
REGION="${1:-us-east-1}"
FUNCTION_NAME="devops-agent-recommendation-collector"

echo "=== DevOps Agent Recommendation Backfill ==="
echo "Account: $(aws sts get-caller-identity --query Account --output text)"
echo "Region:  ${REGION}"
echo "Lambda:  ${FUNCTION_NAME}"
echo

# Check Lambda exists
if ! aws lambda get-function --function-name "${FUNCTION_NAME}" --region "${REGION}" >/dev/null 2>&1; then
  echo "ERROR: Lambda function ${FUNCTION_NAME} not found."
  echo "Deploy the collection stack first (source/collection-module/collection-stack.yaml)."
  exit 1
fi

echo "Invoking recommendation collector..."
RESPONSE=$(aws lambda invoke \
  --function-name "${FUNCTION_NAME}" \
  --region "${REGION}" \
  --payload '{}' \
  --cli-read-timeout 180 \
  /dev/stdout 2>/dev/null)

echo "${RESPONSE}" | head -1 | python3 -m json.tool 2>/dev/null || echo "${RESPONSE}"
echo
echo "Done. Run the Glue crawler in the dashboard account to make results queryable."
echo "  aws glue start-crawler --name devops-agent-crawler-<dashboard-account-id> --region ${REGION}"
