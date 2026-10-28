#!/bin/bash
# redrive.sh - Replays events from the collection stack's failed-events queue
# (devops-agent-failed-events) after you have fixed the cause of the failure.
#
# The queue receives:
#   - collector invocations that still failed after Lambda's retries
#     (Lambda on-failure destination records; the original event is kept), and
#   - events EventBridge could not deliver to a collector (the event itself).
# Each message is replayed synchronously through the same collector. It is
# deleted only after a successful replay, so a message that fails again stays
# in the queue. Replays are idempotent (same S3 key per investigation).
#
# The Coverage table shows each collector's failed-events count
# (failedEventsPending). Run this in that account and Region.
#
# Usage: ./redrive.sh <REGION> [--dry-run]
# Requires: AWS CLI v2 and python3 (both available in AWS CloudShell).
set -euo pipefail

REGION="${1:?Usage: redrive.sh <REGION> [--dry-run]}"
MODE="${2:-}"
QUEUE_URL=$(aws sqs get-queue-url --queue-name devops-agent-failed-events --region "${REGION}" \
  --query QueueUrl --output text)
WORKDIR=$(mktemp -d)
trap 'rm -f "${WORKDIR}"/*; rmdir "${WORKDIR}"' EXIT
OK=0; FAILED=0; SEEN=0

# Prints "<function> <path-of-payload-file>" for one SQS message body (on stdin).
classify() {
  python3 - "$1" <<'PY'
import json, sys
body = json.load(sys.stdin)
payload = body.get('requestPayload', body)          # Lambda destination record, or the raw event
function_arn = body.get('requestContext', {}).get('functionArn', '')
if 'inventory' in function_arn or payload.get('source') == 'aws.events':
    target = 'devops-agent-inventory-collector'
    payload = {}
else:
    target = 'devops-agent-investigation-collector'
with open(sys.argv[1], 'w') as f:
    json.dump(payload, f)
print(target)
PY
}

while true; do
  aws sqs receive-message --queue-url "${QUEUE_URL}" --region "${REGION}" \
    --max-number-of-messages 10 --visibility-timeout 300 --wait-time-seconds 2 \
    --output json > "${WORKDIR}/batch.json"
  COUNT=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("Messages", [])))' "${WORKDIR}/batch.json")
  [ "${COUNT}" -eq 0 ] && break
  for i in $(seq 0 $((COUNT - 1))); do
    SEEN=$((SEEN + 1))
    python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))["Messages"][int(sys.argv[2])]; print(m["Body"])' \
      "${WORKDIR}/batch.json" "${i}" > "${WORKDIR}/body.json"
    HANDLE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Messages"][int(sys.argv[2])]["ReceiptHandle"])' \
      "${WORKDIR}/batch.json" "${i}")
    TARGET=$(classify "${WORKDIR}/payload.json" < "${WORKDIR}/body.json")
    if [ "${MODE}" = "--dry-run" ]; then
      echo "WOULD REPLAY -> ${TARGET}: $(head -c 160 "${WORKDIR}/payload.json")"
      continue
    fi
    ERR=$(aws lambda invoke --function-name "${TARGET}" --payload "fileb://${WORKDIR}/payload.json" \
          --region "${REGION}" --cli-read-timeout 330 --query FunctionError --output text \
          "${WORKDIR}/response.json" || echo "INVOKE_FAILED")
    if [ "${ERR}" = "None" ] || [ -z "${ERR}" ]; then
      aws sqs delete-message --queue-url "${QUEUE_URL}" --receipt-handle "${HANDLE}" --region "${REGION}"
      echo "OK     -> ${TARGET}"
      OK=$((OK + 1))
    else
      echo "FAILED -> ${TARGET}: $(head -c 300 "${WORKDIR}/response.json") (left in queue)"
      FAILED=$((FAILED + 1))
    fi
  done
  # In dry-run, messages are not deleted; one pass is enough to list them.
  [ "${MODE}" = "--dry-run" ] && break
done

echo ""
echo "=== ${SEEN} message(s) seen: ${OK} replayed, ${FAILED} still failing ==="
if [ "${FAILED}" -gt 0 ]; then
  echo "Messages that still fail were left in the queue. Check the collector's CloudWatch Logs."
  exit 1
fi
