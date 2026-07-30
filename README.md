# Guidance for Building a DevOps Agent Centralized Operations Dashboard on AWS

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Cost](#cost)
4. [Prerequisites](#prerequisites)
5. [Deployment](#deployment)
6. [Validation](#validation)
7. [Running the Guidance](#running-the-guidance)
8. [Security](#security)
9. [Next Steps](#next-steps)
10. [Cleanup](#cleanup)
11. [FAQ](#faq)
12. [Revisions](#revisions)
13. [Notices](#notices)

## Overview

This solution provides a centralized operations dashboard for [AWS DevOps Agent](https://docs.aws.amazon.com/devops-agent/latest/userguide/what-is.html) investigations across multiple AWS accounts. It automatically captures investigation data via EventBridge events, stores structured records in Amazon S3, and surfaces insights through Amazon QuickSight dashboards.

### Key Capabilities

- **Multi-account collection** — Automatically captures investigation completion events from any number of workload accounts
- **Mean Time to RCA (MTTR)** — Tracks how quickly DevOps Agent identifies root causes vs. manual investigation baselines
- **Root cause classification** — Cascade view from root cause → mechanism → symptoms with full investigation context
- **Agent effectiveness** — Context window utilization, sub-agents deployed, tool calls per investigation
- **ROI tracking** — Agent cost per investigation ($0.0083/sec) and hours saved vs. manual baseline (configurable, default 60 min)

### Dashboard Sheets

| Sheet | Purpose |
|-------|---------|
| Operations Overview | Volume, distribution by workload/account/priority, trends over time |
| Time to RCA | Average investigation duration, by workload, month-over-month trends |
| Root Cause & Classification | Cascade pivot, root cause descriptions, affected resources |
| Agent Effectiveness | Context window %, sub-agent count, tool calls, compaction events |
| ROI & Cost | Total agent cost, cost per investigation, hours saved vs. baseline |

## Architecture

![Architecture Diagram](img/architecture.png)

### Data Flow

1. **DevOps Agent** completes an investigation in a workload account
2. **Amazon EventBridge** captures the `Investigation Completed` event
3. **AWS Lambda** (investigation collector) fetches journal records via the DevOps Agent API, parses the `investigation_summary` and `utilization` records, and writes a flat JSON file to S3
4. **Amazon S3 Cross-Region Replication** copies data from workload accounts to a centralized dashboard account bucket
5. **AWS Glue Crawler** (every 30 min) discovers the schema and updates the Glue Data Catalog
6. **Amazon Athena** provides SQL access to the investigation data
7. **Amazon QuickSight** renders the 5-sheet operations dashboard

### Accounts

| Account Role | Resources |
|--------------|-----------|
| Workload Account(s) | Lambda functions, EventBridge rules, S3 collection bucket |
| Dashboard Account | Centralized S3 bucket, Glue crawler/database, Athena workgroup, QuickSight analysis |

## Cost

### Estimated Monthly Cost (100 investigations/month)

| Service | Usage | Estimated Cost |
|---------|-------|---------------|
| AWS Lambda | 100 invocations × 500ms × 512MB | $0.01 |
| Amazon S3 | 100 objects × 3KB + storage | $0.01 |
| S3 Cross-Region Replication | 100 objects | $0.01 |
| AWS Glue Crawler | 48 runs/day × 30 days | $0.50 |
| Amazon Athena | ~10 queries/day × 10MB scanned | $0.15 |
| Amazon QuickSight | 1 author license | $24.00 |
| **Total** | | **~$25/month** |

> QuickSight is the primary cost driver. Reader sessions ($0.30/session, max $5/reader/month) apply for additional viewers.

## Prerequisites

### Required

- AWS accounts with [AWS DevOps Agent](https://docs.aws.amazon.com/devops-agent/latest/userguide/what-is.html) enabled
- AWS CLI v2 configured with credentials for all accounts
- Amazon QuickSight Enterprise Edition enabled in the dashboard account

### Strongly Recommended: Tag Your AgentSpaces

Tag every AgentSpace with `workload=<workload-name>`:

```bash
aws devops-agent tag-resource \
  --resource-arn arn:aws:aidevops:us-east-1:<account-id>:agentspace/<agentspace-id> \
  --tags workload=payments \
  --region us-east-1
```

**This is not a hard requirement — the solution degrades rather than fails.** An untagged AgentSpace is still collected in full: duration, root cause, symptoms, effectiveness metrics, and cost all populate normally. Only the workload attribution is lost, and the record lands with `workloadName=unknown`.

What you lose without tags is the grouping dimension that most of the dashboard is organized around:

| Sheet | Impact of missing tags |
|---|---|
| Operations Overview | "By Workload" chart collapses into a single `unknown` slice |
| Time to RCA | Cannot compare MTTR across workloads |
| Root Cause & Classification | Cascade pivot loses its top grouping level |
| Agent Effectiveness | Cannot identify which workloads drive high context usage |
| ROI & Cost | Cannot attribute agent spend to a workload or team |

The `unknown` value is deliberately visible rather than silent, so a missing tag shows up as a labelled gap in the dashboard instead of an absent row. To fix it: tag the AgentSpace, then re-run the backfill script. Because the S3 key is derived from execution ID and date rather than workload name, the corrected record overwrites the old one in place — no duplicates, no cleanup.

Use one tag value per logical application or service. The value becomes the workload label everywhere in the dashboard, so keep it stable — renaming it later splits that workload's history into two series.

### Permissions

- CloudFormation deployment: `Admin` or equivalent IAM role in each account
- QuickSight: Author permissions in the dashboard account

## Deployment

### Deployment Order Matters

Deploy in this order. The dashboard account **must** be first.

```
Step 1  ──▶  Dashboard Account      (creates the centralized S3 bucket)
Step 2  ──▶  Each Workload Account  (configures replication INTO that bucket)
Step 3  ──▶  Dashboard Account      (creates QuickSight datasets + analysis)
Step 4  ──▶  Each Workload Account  (optional: backfill historical data)
```

**Why the order is fixed:** the collection stack configures S3 replication with the dashboard bucket as its destination. Amazon S3 rejects a replication configuration whose destination bucket does not exist, returning `Destination bucket must exist` (HTTP 400, `InvalidRequest`). If you deploy the collection stack first, it will fail at the `CollectionBucket` resource and roll back.

There is no reverse dependency, so the order is safe: the dashboard bucket policy authorizes replication by account ID (`aws:PrincipalAccount`) rather than by naming a replication role ARN. Account IDs are known up front, and no workload-account resource needs to exist when Step 1 runs.

> **Note:** This is the opposite of the [Cloud Intelligence Dashboards](https://docs.aws.amazon.com/guidance/latest/cloud-intelligence-dashboards/data-collection-deployment.html) ordering, which deploys read permissions in the Management Account first. CID uses a *pull* model — a central Lambda assumes a role into each source account, so the role must exist first. This solution uses a *push* model (S3 replication), which inverts the dependency.

### Step 1. [Dashboard Account] Deploy the Dashboard Stack

Creates the centralized S3 bucket, Glue database and crawlers, and the QuickSight service role.

```bash
DASHBOARD_ACCOUNT_ID=<your-dashboard-account-id>
WORKLOAD_ACCOUNT_IDS=<comma-separated-workload-account-ids>
QUICKSIGHT_USER_ARN=<your-quicksight-user-arn>

aws cloudformation deploy \
  --template-file source/dashboard-account/dashboard-stack.yaml \
  --stack-name devops-agent-dashboard \
  --parameter-overrides \
    WorkloadAccountIds="${WORKLOAD_ACCOUNT_IDS}" \
    QuickSightUserArn="${QUICKSIGHT_USER_ARN}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1
```

List **every** workload account you intend to onboard in `WorkloadAccountIds`. Adding an account later requires updating this stack (see [Adding New Workload Accounts](#adding-new-workload-accounts)).

Wait for `CREATE_COMPLETE` before continuing:

```bash
aws cloudformation wait stack-create-complete \
  --stack-name devops-agent-dashboard --region us-east-1
```

### Step 2. [Each Workload Account] Deploy the Collection Module

Creates the collection bucket with replication, the collector Lambda, and the EventBridge rule.

```bash
DASHBOARD_ACCOUNT_ID=<your-dashboard-account-id>
DASHBOARD_BUCKET=devops-agent-dashboard-centralized-${DASHBOARD_ACCOUNT_ID}

aws cloudformation deploy \
  --template-file source/collection-module/collection-stack.yaml \
  --stack-name devops-agent-collection \
  --parameter-overrides \
    DashboardAccountId="${DASHBOARD_ACCOUNT_ID}" \
    DashboardBucketName="${DASHBOARD_BUCKET}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1
```

Repeat in each workload account. These are independent of each other and can run in parallel.

### Step 3. [Dashboard Account] Set Up the QuickSight Dashboard

Run the Glue crawler first so the Athena table exists, then apply the dashboard.

```bash
aws glue start-crawler \
  --name devops-agent-crawler-${DASHBOARD_ACCOUNT_ID} --region us-east-1

# Wait for state to return to READY, then:
bash scripts/setup-dashboard.sh ${DASHBOARD_ACCOUNT_ID} us-east-1
```

The crawler needs at least one object in the bucket to infer a schema. If you have no investigations yet, either trigger one or run Step 4 first.

### Step 4. [Each Workload Account] Backfill Historical Data (Optional)

EventBridge only fires on new events, so investigations that completed before Step 2 are not captured. To load them:

```bash
bash scripts/backfill-historical.sh us-east-1
```

See [Historical Backfill](#historical-backfill) for details and limitations.

## Validation

After deployment, verify the pipeline works end-to-end:

1. **Tag an AgentSpace** with `workload=<name>` if not already done
2. **Trigger an investigation** in the DevOps Agent console
3. **Check S3** for the output file:
   ```bash
   aws s3 ls s3://devops-agent-collection-${ACCOUNT_ID}-us-east-1/investigations-v2/ --recursive
   ```
4. **Wait for replication** (~1-2 minutes) and verify in the dashboard bucket:
   ```bash
   aws s3 ls s3://devops-agent-dashboard-centralized-${DASHBOARD_ACCOUNT_ID}/investigations-v2/ --recursive
   ```
5. **Run the Glue crawler** (or wait for the 30-min schedule):
   ```bash
   aws glue start-crawler --name devops-agent-crawler-${DASHBOARD_ACCOUNT_ID}
   ```
6. **Open QuickSight** and verify data appears in the dashboard

## Running the Guidance

### Normal Operation

The solution runs automatically:
- EventBridge triggers Lambda on every investigation completion
- S3 replication copies data to the dashboard account within minutes
- Glue crawler updates the table schema every 30 minutes
- QuickSight queries Athena in real-time (DIRECT_QUERY mode)

### Adding New Workload Accounts

Order matters here too — update the dashboard bucket policy **before** deploying the new collection stack.

1. **[Dashboard Account]** Update the dashboard stack, adding the new account to `WorkloadAccountIds`:
   ```bash
   aws cloudformation deploy \
     --template-file source/dashboard-account/dashboard-stack.yaml \
     --stack-name devops-agent-dashboard \
     --parameter-overrides \
       WorkloadAccountIds="111111111111,222222222222,333333333333" \
       QuickSightUserArn="${QUICKSIGHT_USER_ARN}" \
     --capabilities CAPABILITY_NAMED_IAM --region us-east-1
   ```
2. **[New Account]** Tag AgentSpaces with `workload=<name>`
3. **[New Account]** Deploy the collection stack (Step 2)
4. **[New Account]** Optionally run the backfill script

No dashboard or dataset changes are needed. The crawler discovers the new `account_id=` partition automatically, and existing visuals pick it up.

### Backfilling Historical Investigations

EventBridge only fires on new events, so investigations completed before deployment need a one-time backfill:

```bash
# In each workload account
bash scripts/backfill-historical.sh us-east-1 --dry-run   # preview
bash scripts/backfill-historical.sh us-east-1             # execute
```

The script walks `ListAgentSpaces` → `ListBacklogTasks`, selects tasks where `taskType=INVESTIGATION` and `status=COMPLETED`, and replays each through the collector Lambda. It is idempotent — safe to re-run. `--dry-run` works before the collection stack is deployed.

## Security

- **Read-only against DevOps Agent.** The collector holds five Read/List actions and no Write actions. It cannot create, modify, or delete AgentSpaces, investigations, or mitigations.
- **No cross-account role assumption.** Data moves by S3 replication (push). The dashboard account never calls into a workload account and holds no workload-account credentials.
- **Least-privilege resource scoping.** DevOps Agent reads are scoped to `arn:aws:aidevops:<region>:<account>:agentspace/*`. S3 writes are scoped to the local collection bucket.
- **Account-conditioned bucket policy.** The dashboard bucket uses `Principal: "*"` narrowed by `aws:PrincipalAccount` to the explicit workload account list. Only listed accounts can replicate.
- **Encryption.** S3 buckets use SSE-S3 by default. Replication preserves encryption.
- **No customer application data.** Collected records contain investigation metadata, root-cause text, and AWS resource identifiers — not application payloads or logs.
- **Encryption at rest.** All buckets set SSE-S3 with S3 Bucket Keys explicitly, rather than relying on the account default, so the template cannot be weakened by account-level changes.
- **Public access blocked.** All buckets set `PublicAccessBlockConfiguration`. The centralized bucket permits bucket policies (required for cross-account replication) but blocks public ACLs and restricts public bucket access.
- **Bounded log retention.** The collector's log group is declared with a 30-day default rather than left to Lambda's "Never expire".

Full detail: [permissions model](docs/implementation-guide.md#permissions-model).

## Next Steps

- **Alerting** — Add CloudWatch alarms on investigation duration exceeding thresholds
- **Cost allocation tags** — Tag Lambda and S3 resources for showback
- **Reader access** — Share the QuickSight dashboard with additional readers

## Cleanup

### Remove Dashboard Resources

```bash
bash scripts/teardown-dashboard.sh ${DASHBOARD_ACCOUNT_ID} us-east-1
```

### Remove CloudFormation Stacks

```bash
# Dashboard account
aws cloudformation delete-stack --stack-name devops-agent-dashboard --region us-east-1

# Each workload account
aws cloudformation delete-stack --stack-name devops-agent-collection --region us-east-1
```

### Remove S3 Data

Both buckets have **versioning enabled**, so `aws s3 rm --recursive` is not sufficient — it
deletes current object versions but leaves noncurrent versions and delete markers behind, and
`aws s3 rb` then fails with `BucketNotEmpty`.

The simplest path is the S3 console's **Empty bucket** action, which purges all versions in
one step. To do it from the CLI, delete every version and delete marker first:

```bash
# Purge all versions and delete markers, then remove the bucket.
# Repeat the delete-objects call if the bucket held more than 1,000 versions.
purge_bucket() {
  BUCKET=$1
  aws s3api delete-objects --bucket "${BUCKET}" --delete "$(
    aws s3api list-object-versions --bucket "${BUCKET}" --output json \
      --query '{Objects: [Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers[].{Key:Key,VersionId:VersionId}][]}'
  )"
  aws s3 rb "s3://${BUCKET}"
}

# Dashboard account
purge_bucket devops-agent-dashboard-centralized-${DASHBOARD_ACCOUNT_ID}

# Each workload account -- note the region suffix in the bucket name
purge_bucket devops-agent-collection-${ACCOUNT_ID}-us-east-1
```

**Purge the buckets before deleting the CloudFormation stacks.** The buckets are declared
`DeletionPolicy: Delete`, so stack deletion attempts to remove them — and fails with
`The bucket you tried to delete is not empty. You must delete all versions in the bucket.`
if any object versions remain. Order matters: purge first, then delete the stack.

## FAQ

**Q: Which stack do I deploy first?**
A: The **dashboard account** stack, always. The collection stack configures S3 replication pointing at the dashboard bucket, and S3 rejects a replication configuration whose destination does not exist (`Destination bucket must exist`, HTTP 400). Deploying collection first fails and rolls back. Note this is the reverse of the Cloud Intelligence Dashboards order, because CID pulls (assumes a role into source accounts) while this solution pushes (S3 replication).

**Q: Do I need management-account or Organizations access?**
A: No. There are no StackSets, no Organizations trusted access, and no cross-account role assumption. Each stack deploys independently with account-local permissions.

**Q: Does the dashboard account get access into my workload accounts?**
A: No. Data flows one way via S3 replication. The dashboard account never initiates a call into a workload account and holds no credentials for them.

**Q: What DevOps Agent permissions does the collector need?**
A: Five read/list actions only — `ListAgentSpaces`, `GetAgentSpace`, `ListJournalRecords`, `ListExecutions`, `ListBacklogTasks`. No write actions. All but `ListAgentSpaces` are scoped to `agentspace/*` in the local account and region. See the [permissions model](docs/implementation-guide.md#permissions-model).

**Q: What about investigations from before I deployed this?**
A: Run `scripts/backfill-historical.sh` in each workload account. It discovers past executions through the API and replays them through the collector Lambda. Limited by DevOps Agent journal retention — anything aged out cannot be recovered.

**Q: The stack failed with `InsufficientCapabilitiesException`. Why?**
A: Both stacks create IAM roles with explicit names, which requires `--capabilities CAPABILITY_NAMED_IAM`. `CAPABILITY_IAM` alone is not sufficient.

**Q: Why declare the log group at all?**
A: If Lambda auto-creates it, retention defaults to "Never expire" and logs accumulate indefinitely as an invisible cost. The template sets 30 days by default, adjustable via the `LogRetentionDays` parameter.

**Q: Is the RCA time stable if an investigation is revisited or mitigated later?**
A: Yes. `durationMinutes` is computed from journal records only — earliest record to the `investigation_summary` record. Journal records are append-only and their timestamps never change, so the value is fixed once the RCA is produced. Task-level timestamps do drift (observed by up to nine days after a mitigation), which is exactly why they are not used. See [Time to RCA](docs/implementation-guide.md#time-to-rca--stability-guarantee).

**Q: Will re-running the backfill change my existing numbers?**
A: No. Live capture and backfill derive timing identically from the same journal records, so a re-run recomputes the same duration, the same date, and therefore the same S3 key — it overwrites in place with identical values.

**Q: Why does the backfill filter on task status instead of execution status?**
A: Because a successful execution reports `executionStatus: STOPPED`, not `COMPLETED` — the Execution enum (`FAILED | RUNNING | STOPPED | CANCELED | TIMED_OUT`) contains no success value at all. Task-level `status` is the field that actually says `COMPLETED`.

**Q: Is the backfill safe to run twice?**
A: Yes. The S3 key is derived from `executionId` plus investigation date, so re-runs overwrite in place rather than duplicating rows.

**Q: What happens if an AgentSpace isn't tagged with `workload`?**
A: The investigation is still captured but `workloadName` shows as "unknown". Tag the AgentSpace, then re-run the backfill script — it overwrites the existing record in place and corrects the value.

**Q: Can I change the 60-minute manual baseline for ROI calculations?**
A: Yes. The `hoursSaved` calculated field in QuickSight uses the formula `(60 - durationminutes) / 60`. Edit the calculated field in QuickSight to adjust the baseline, or create a QuickSight parameter for dynamic adjustment.

**Q: How much context window utilization is normal?**
A: Typical investigations use 20-50% of the context window. Values above 80% with compaction events suggest very complex investigations that may benefit from workload splitting.

**Q: What's the agent cost calculation?**
A: DevOps Agent costs $0.0083/second of investigation time. The `agentCostUsd` field is calculated as `durationMinutes × 60 × $0.0083`.

**Q: Can I add more accounts later?**
A: Yes. Deploy the collection stack to the new account and update the dashboard bucket policy. No changes needed to the dashboard itself — the crawler picks up new data automatically.

**Q: What if the Glue crawler finds schema changes?**
A: The crawler is configured with `UpdateBehavior: UPDATE_IN_DATABASE`. New columns are added automatically. Removed columns are logged but not deleted.

## Revisions

| Date | Description |
|------|-------------|
| 2026-07-29 | Initial release — 5-sheet dashboard with investigation collection and historical backfill |

## Notices

This solution is provided as-is under the MIT-0 license. See [LICENSE](LICENSE) for details.

This solution uses the AWS DevOps Agent API which is currently in preview. API behavior and event schemas may change.

The agent cost rate ($0.0083/second) is based on current DevOps Agent pricing. Verify current pricing at [AWS DevOps Agent Pricing](https://aws.amazon.com/devops-agent/pricing/).
