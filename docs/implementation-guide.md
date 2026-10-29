# Implementation Guide

Design detail behind the [README](../README.md). The README tells you how to deploy and operate the solution; this guide explains why it is built the way it is, and documents the data it produces.

## Permissions Model

The solution is read-only against DevOps Agent and uses a push-based data path. No component assumes a role into another account, and no component holds write access to DevOps Agent.

### Trust boundaries

```
┌─ Workload account, per Region ────────────────────┐
│                                                   │
│  Investigation collector ─reads─▶ DevOps Agent API │
│  Inventory collector     ─reads─▶ (same account +  │
│         │                          Region only)    │
│         └──writes──▶ Staging bucket                │
│                         │                          │
│  Replication role ──────┘                          │
└─────────┼─────────────────────────────────────────┘
          │ push: S3 replication (cross-account, cross-Region when needed)
          ▼
┌─ Dashboard account, analytics Region ─────────────┐
│  Dashboard bucket  (allows aws:PrincipalOrgID     │
│                     or listed accounts only)      │
│  QuickSight ──▶ Athena ──▶ Glue tables ──▶ bucket │
└───────────────────────────────────────────────────┘
```

The dashboard account has no permissions into workload accounts. Compromising the dashboard account grants no access to workload accounts.

### Role names and Regions

The collection stack creates three roles, each named with the Region: `devops-agent-collector-<region>`, `devops-agent-inventory-<region>`, and `devops-agent-replication-<region>`. IAM role names must be unique across every Region of an account; the suffix is what lets the same stack be deployed into several Regions of one account, by hand or by a multi-Region StackSet. The account ID is not in the name because IAM names are already account-scoped.

### Investigation collector role — `devops-agent-collector-<region>`

| Action | Resource | Why |
|---|---|---|
| `aidevops:GetAgentSpace` | `agentspace/*` in this account and Region | Workload label (tag, else name) |
| `aidevops:ListJournalRecords` | `agentspace/*` in this account and Region | Investigation summary and utilization records |
| `s3:PutObject` | `<staging-bucket>/investigations-v2/*` | Write investigation records |
| `sqs:SendMessage` | The failed-events queue | Lambda on-failure destination |
| `AWSLambdaBasicExecutionRole` | Own log group | CloudWatch Logs |

### Inventory collector role — `devops-agent-inventory-<region>`

| Action | Resource | Why |
|---|---|---|
| `aidevops:ListAgentSpaces` | `*` | Discovery. The [Service Authorization Reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_devops-agent.html) defines no resource type for it |
| `aidevops:GetAgentSpace`, `aidevops:ListGoals`, `aidevops:ListRecommendations` | `agentspace/*` in this account and Region | Current recommendations |
| `s3:PutObject` | `<staging-bucket>/recommendations-v1/*`, `<staging-bucket>/collector-status/*` | Write recommendations and the status record |
| `s3:DeleteObject` | `<staging-bucket>/recommendations-v1/*` | Remove recommendations of deleted Agent Spaces |
| `s3:ListBucket`, `s3:GetObject` | The staging bucket | Replication health check (object `ReplicationStatus`) |
| `sqs:SendMessage`, `sqs:GetQueueAttributes` | The failed-events queue | On-failure destination; report the queue depth |

Every `aidevops` action granted is Read or List. **`aidevops:UpdateRecommendation` is never granted.** It exists in the API, and a reporting dashboard must not accept or reject a recommendation on the customer's behalf.

DevOps Agent exposes `aws:ResourceTag/${TagKey}` as a condition key on the `agentspace` resource type, so the collectors could be restricted to tagged Agent Spaces. This is not done: untagged Agent Spaces are collected and labelled with their name. Tag-gating would make them silently absent instead.

### Replication role — `devops-agent-replication-<region>`

Standard S3 replication permissions, assumed by `s3.amazonaws.com`, as documented in [Setting up permissions for live replication](https://docs.aws.amazon.com/AmazonS3/latest/userguide/setting-repl-config-perm-overview.html):

| Action | Resource |
|---|---|
| `s3:GetReplicationConfiguration`, `s3:ListBucket` | Staging bucket |
| `s3:GetObjectVersionForReplication`, `s3:GetObjectVersionAcl`, `s3:GetObjectVersionTagging` | Staging bucket objects |
| `s3:ReplicateObject`, `s3:ReplicateDelete`, `s3:ReplicateTags`, `s3:ObjectOwnerOverrideToBucketOwner` | Dashboard bucket objects |

`ObjectOwnerOverrideToBucketOwner` pairs with `AccessControlTranslation: Owner: Destination`, so replicas are owned by the dashboard account and readable by Athena and QuickSight there.

The role references the staging bucket by constructed name rather than `!GetAtt`: the bucket's replication configuration references the role, so a reference back would be circular.

#### Replication rules

Three rules, one per prefix: `investigations-v2/`, `recommendations-v1/`, and `collector-status/`. Because the rules use `Filter`, they are on S3's V2 replication schema, which requires an explicit unique `Priority` and an explicit `DeleteMarkerReplication` on every rule. Omitting either fails the stack with `Priority must be specified for this version of Cross Region Replication configuration schema`.

`DeleteMarkerReplication: Enabled` keeps the dashboard in agreement with the source. When the inventory collector removes the recommendations of a deleted Agent Space, the delete marker replicates and the rows disappear from the dashboard too. The same property is why a staging bucket must never be emptied with `aws s3 rm`, which writes delete markers (see the README's Cleanup section).

The destination is named by bucket ARN only. S3 resolves the destination Region, so the same rules serve same-Region and cross-Region delivery.

### Dashboard bucket policy

The policy authorizes **accounts or organizations**, not roles or Regions, following the [cross-account replication guidance](https://docs.aws.amazon.com/AmazonS3/latest/userguide/setting-repl-config-perm-overview.html). It is built from two parameters; at least one must be set (a CloudFormation `Rules` assertion enforces it):

| Parameter | Statement | Effect |
|---|---|---|
| `OrganizationIds` | `Principal: "*"` with `StringEquals: aws:PrincipalOrgID` | Any account in the listed organizations may replicate. [`aws:PrincipalOrgID`](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_condition-keys.html) automatically includes accounts as they join |
| `WorkloadAccountIds` | `Principal: {AWS: [account IDs]}` | Only the listed accounts may replicate |

Each grants the object actions (`ReplicateObject`, `ReplicateDelete`, `ReplicateTags`, `ObjectOwnerOverrideToBucketOwner`) and the bucket actions from the S3 example policy (`List*`, `GetBucketVersioning`, `PutBucketVersioning`).

Why this shape:

- **No ordering trap.** Naming a replication role ARN as the principal would fail with `Invalid principal in policy`, because the role does not exist when the dashboard stack deploys. Account IDs and organization IDs are known up front.
- **Region-agnostic.** An allowed account can replicate from every Region it runs a collector in; adding a Region needs no dashboard change.
- **Non-public, so Block Public Access stays fully on.** S3 treats a policy as non-public when it grants only to fixed principals or a fixed `aws:PrincipalOrgID` ([The meaning of "public"](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html)). All four Block Public Access settings are enabled on every bucket.

A final statement denies any request that does not use TLS.

### QuickSight service role

| Action | Resource |
|---|---|
| `athena:StartQueryExecution`, `GetQueryExecution`, `GetQueryResults`, `StopQueryExecution`, `GetWorkGroup` | The solution's Athena workgroup |
| `glue:GetDatabase(s)`, `GetTable(s)`, `GetPartition(s)`, `BatchGetPartition` | The solution's catalog, database, and tables |
| `s3:GetObject`, `s3:ListBucket`, `s3:GetBucketLocation` | Dashboard bucket and Athena results bucket |
| `s3:PutObject`, `s3:AbortMultipartUpload` | Athena results bucket |

### Deployer permissions

| Step | Where | Needs |
|---|---|---|
| 1 | Dashboard account, analytics Region | CloudFormation; `iam:CreateRole`, `iam:PutRolePolicy`; S3; Glue; Athena |
| 2 | Dashboard account, analytics Region | QuickSight author: create/update data source, datasets, analysis, dashboard |
| 3a | Management account or StackSets delegated administrator | CloudFormation StackSets with service-managed permissions |
| 3b | Each workload account × Region | CloudFormation; IAM; S3; Lambda; EventBridge; SQS |
| 4 | Each workload account with history | `lambda:InvokeFunction` on both collectors; the `aidevops` read actions above plus `aidevops:ListBacklogTasks` and `aidevops:ListExecutions` |

## Failure Handling

The design goal is that nothing fails silently: every failure is either retried automatically, or kept and made visible with a way to repair it.

### Retry and dead-letter chain

```
DevOps Agent event
  └─ EventBridge rule ──(cannot invoke)──────────────────────────┐
       └─ Lambda, asynchronous invocation                        │
            ├─ SDK adaptive retries on throttling                │
            ├─ function raises → Lambda retries twice            │
            └─ still failing → on-failure destination ───────────┤
                                                                 ▼
                                    SQS: devops-agent-failed-events (14 days)
                                                                 │
                           depth reported in the collector status record
                                                                 │
                                         scripts/redrive.sh replays each message
```

- **Functions raise on failure.** A Lambda that catches an error and returns normally is recorded as a success, so neither retries nor destinations apply. Both collectors let errors propagate: a failed journal read, a failed S3 write, or a malformed event raises.
- **Two deliberate exceptions.** A failed `GetAgentSpace` does not abort the record; it only loses the label, which becomes `unknown`. A completed investigation with no `investigation_summary` raises a named error, `NoInvestigationSummary`, so `backfill.sh` can distinguish "journal aged out" (skip) from a real failure.
- **Async invocation settings.** `MaximumRetryAttempts: 2` and an `OnFailure` destination on the failed-events queue, through `AWS::Lambda::EventInvokeConfig`. By default Lambda retries an asynchronous invocation twice and then discards it; the destination keeps it, including the original event.
- **EventBridge dead-letter queue.** Both rule targets set `DeadLetterConfig` to the same queue. The queue policy allows `events.amazonaws.com` to send only from those two rules (`aws:SourceArn`), as described in [Using dead-letter queues to process undelivered events](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-rule-dlq.html).
- **One queue per collector.** SQS queue names are unique per account and Region, so each collection stack has its own `devops-agent-failed-events`.

### Replication health

S3 can publish `s3:Replication:OperationFailedReplication` events, but only when replication metrics are enabled on the rule ([Receiving replication failure events](https://docs.aws.amazon.com/AmazonS3/latest/userguide/replication-metrics-events.html)), and replication metrics are billed at the same rate as CloudWatch custom metrics ([S3 CRR replication time](https://repost.aws/knowledge-center/s3-crr-replication-time)). Across hundreds of collectors that is a standing cost to catch a rare event. Instead, the inventory collector checks the `ReplicationStatus` of the previous status record and of investigation objects written in the last 8 days (up to 200 objects per run) and reports the count of `FAILED` objects. The check costs a few `HEAD` requests every 2 days.

### Recovery tools

| Tool | Use it when | Behavior |
|---|---|---|
| `scripts/redrive.sh <region>` | *Failed events pending* > 0, after fixing the cause | Replays each queued event through the collector it was meant for; deletes a message only after a successful replay |
| `scripts/backfill.sh <region>` | After fixing replication or permissions; after re-tagging; for accounts with earlier history | Re-reads every finished investigation from DevOps Agent and rewrites its record. Rewrites create new object versions, which replicate |

Both are idempotent, because every record has one fixed S3 key.

### Behaviour at scale

- **Athena scans the whole prefix.** `investigations_v2` and `recommendations_v1` are flat external tables with no partition columns and no partition projection. The S3 keys are laid out `account_id=.../agentspace_id=.../`, but because the tables declare no partitions, every query reads all JSON under the prefix. Query cost grows with the total data volume, not with the slice you query. If volume grows large, the cheapest fix is Athena partition projection on `account_id` and `agentspace_id` — the keys are already in the layout, so no rewrite of stored data is needed.
- **One queue, four message shapes.** The failed-events queue receives from four producers: investigation-collector async failures, inventory-collector async failures, and the two EventBridge rule dead-letter configs. `scripts/redrive.sh` branches on the shape of each message. Adding a fifth producer means teaching `redrive.sh` a fifth shape.

## Investigation Collection

### Events captured

The EventBridge rule matches source `aws.aidevops` with these detail types, from the [DevOps Agent EventBridge integration](https://docs.aws.amazon.com/devopsagent/latest/userguide/configuring-integrations-and-knowledge-integrating-devops-agent-into-event-driven-applications-using-amazon-eventbridge-index.html):

```json
{"source": ["aws.aidevops"],
 "detail-type": ["Investigation Completed", "Investigation Failed", "Investigation Timed Out"]}
```

`Investigation Cancelled` and `Investigation Skipped` are deliberately excluded: neither is an attempt by the agent that succeeded or failed.

Per the [events detail reference](https://docs.aws.amazon.com/devopsagent/latest/userguide/integrating-devops-agent-into-event-driven-applications-using-amazon-eventbridge-devops-agent-events-detail-reference.html), `detail.metadata` carries `agent_space_id`, `task_id`, and `execution_id` — the last only once an execution has been assigned — and `detail.data` carries `priority`, `status`, `created_at`, and `updated_at`. Fields with no value are omitted rather than set to null.

### Live-service contract dependencies

This solution depends on three independent names that must each match the live DevOps Agent service. They are easy to assume-copy wrong, and a new service's contract can still change during its GA ramp:

| Surface | Value used | Where |
|---|---|---|
| EventBridge event | `source: aws.aidevops` + the three detail types above | collection stack rule |
| IAM actions | `aidevops:` prefix | collector and inventory roles |
| SDK client | `boto3.client('devops-agent')` and its API names | collector Lambda code |

If any one drifts from the live service, every deployment of this guidance is affected the same way. The two failure shapes differ, and that difference matters:

- **Wrong SDK client or API name — fails loudly.** Every invocation raises, the failed-events queue fills, and the Coverage table shows `ERROR`. Visible within minutes.
- **Wrong event `source` or detail type — fails silently.** No error is raised, the failed-events queue stays empty, and the dashboard simply stays empty while looking healthy. This is the more dangerous case.

**Verify the contract after deploying:** trigger one investigation and confirm a record appears. An empty dashboard **with an empty failed-events queue** points to the event pattern, not an outage — compare the live event `source` and detail type against the table above.

### Completed investigations

The collector calls `ListJournalRecords` for the execution and reads two record types:

- **`investigation_summary`** — findings, symptoms, and gaps in one structured object. It is the single source for everything the dashboard shows about the investigation's content.
- **`utilization`** — context window, compactions, sub-agents, and tool calls. An execution can have several; the collector keeps the one with the highest context-window utilization, which is the most complete.

`content` is returned either as a JSON string or as an object depending on the record; both are handled.

### Failed and timed-out investigations

These produce no summary. The collector writes a status-only record: identifiers, workload label, `status` (`FAILED` or `TIMED_OUT`), priority, and a date from the event's `updated_at`. There is no duration, and no findings. If the event has no `execution_id`, the record is keyed on `task-<task_id>`, which is equally immutable.

Dashboard investigation metrics filter to `status = 'COMPLETED'`, so failed and timed-out records never affect resolution rate, time to RCA, or cost. They are counted per collector on the Coverage table.

## Historical Backfill

EventBridge only delivers events that occur after its rule exists. `scripts/backfill.sh` loads what came before, for accounts that already had DevOps Agent history when the collection stack was deployed. Accounts that adopt DevOps Agent afterwards never need it.

### Discovery chain

```
ListAgentSpaces                               -> agentSpaceId[]          (per Region)
  └─ ListBacklogTasks(agentSpaceId)           -> taskId, taskType, status, priority, updatedAt
       └─ ListExecutions(agentSpaceId, taskId) -> executionId where agentType == ops1
            └─ invoke the investigation collector with an event shaped like the live one
```

Tasks are selected when `taskType == INVESTIGATION` and `status` is `COMPLETED`, `FAILED`, or `TIMED_OUT`. `taskType` also takes `EVALUATION` and other values ([Task](https://docs.aws.amazon.com/devopsagent/latest/APIReference/API_Task.html)), which never produce an investigation summary.

### Task status, not execution status

Only the task-level field indicates success:

| Level | Field | Value observed for a successful investigation |
|---|---|---|
| Task (`ListBacklogTasks`) | `status` | `COMPLETED` |
| Execution (`ListExecutions`) | `executionStatus` | `STOPPED` |

The execution enum (`FAILED | RUNNING | STOPPED | CANCELED | TIMED_OUT`) has no success value, so filtering executions for `COMPLETED` matches nothing.

### One task, several executions

An investigation task carries more than one execution. `agentType: ops1` is the investigation; siblings include `taskChat` (chat, no summary) and `mitigation`. The backfill selects `ops1`. Do not infer the type from the execution ID — formats vary (`exe-ops1-` prefixed, bare UUID, and dashless hex have all been observed).

### Why a synthetic event

Backfill invokes the same collector Lambda with an event shaped like the live EventBridge event, rather than building records itself. There is one implementation of journal parsing, timing, cost, and the S3 key, so backfilled and live records are identical by construction.

The script invokes the collector synchronously and reads the result. `NoInvestigationSummary` means the journal has aged out, and is reported as `SKIP`; any other error is `FAIL`, and the script exits non-zero. After each Region it runs the inventory collector once, so the recommendations and the Coverage row are current immediately.

### Limitations

| Limitation | Detail |
|---|---|
| Journal retention | Only what DevOps Agent still retains can be recovered. Aged-out investigations are skipped |
| Region scope | Each run sees only the Regions it is given; Agent Spaces are Regional |
| Credentials | Runs as the current credentials, in one account. For many accounts, run it per account from your local terminal, only where there was earlier history |
| Throttling | The script pauses 200 ms between investigations, and the collector retries throttled calls |

## Time to RCA — Stability Guarantee

`durationMinutes` must mean the same thing every time it is computed. Both endpoints come from **journal records**, which are append-only:

| Endpoint | Source |
|---|---|
| start | earliest journal record `createdAt` for the execution |
| end | the `investigation_summary` record's `createdAt` — the moment the RCA existed |

`investigationDate` and `investigationMonth` derive from the same end timestamp.

Alternatives were rejected:

- **EventBridge `time`** is the time the investigation was last updated, not when the RCA was written ([events detail reference](https://docs.aws.amazon.com/devopsagent/latest/userguide/integrating-devops-agent-into-event-driven-applications-using-amazon-eventbridge-devops-agent-events-detail-reference.html)). Live capture and backfill would disagree, and a re-run could change stored numbers.
- **`task.updatedAt`** moves forward on any later activity — a mitigation, a chat, a revisit. Measured across five real tasks, four had moved between three hours and nine days after the investigation finished.
- **`execution.updatedAt`** is stable, but measures when the execution stopped, not when the RCA became available, and needs an extra call.

So the metric is immutable once the summary exists, and a re-run of backfill is a true no-op for unchanged investigations: same duration, same date, same S3 key. A negative duration would indicate out-of-order journal records; it is clamped to zero.

## Data Model

Every record carries its account and Agent Space Region as fields, so each object is self-describing wherever it is read.

### Investigation record — `investigations-v2/`

| Field | Type | Description |
|-------|------|-------------|
| executionId | string | Investigation execution ID (empty for a failed record that had none) |
| taskId | string | DevOps Agent task ID |
| agentSpaceId | string | Agent Space ID |
| workloadName | string | `workload` tag, else the Agent Space name, else `unknown` |
| accountId | string | Account that owns the Agent Space |
| agentSpaceRegion | string | Region of the Agent Space and its collector. **Not** the Region of the investigated resources |
| status | string | `COMPLETED`, `FAILED`, or `TIMED_OUT` |
| priority | string | `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`, `MINIMAL` |
| collectorVersion | string | Solution version that wrote the record |
| investigationStartedAt | string | Earliest journal record, ISO-8601 UTC (completed only) |
| investigationCompletedAt | string | The `investigation_summary` record's time (completed); the event's `updated_at` (failed, timed out) |
| durationMinutes | number | Time to RCA (completed only) |
| investigationDate / investigationMonth | string | `YYYY-MM-DD` / `YYYY-MM` |
| resolved | boolean | A `root_cause` finding exists |
| consoleUrl | string | Link to the execution in the DevOps Agent console |
| symptoms, causes, gaps | array[string] | Titles from the summary |
| rootCause, rootCauseDescription | string | Root-cause title and narrative |
| relatedResources | array[string] | Resource labels as written by the agent — not ARNs |
| symptomCount, causeCount, gapCount, resourceCount | integer | Array lengths |
| contextWindowUtilization | number | Context window used, 0–100 |
| compactionCount | integer | Context compaction events |
| subagentsUsed / subagentCount | array[string] / integer | Sub-agents deployed |
| totalToolCalls | integer | Sum of tool calls. Per-tool detail is not stored |
| agentCostUsd | number | List-rate cost at $0.0083 per agent-second |

### Recommendation record — `recommendations-v1/`

One JSON Lines object per Agent Space (`current.json`), one line per recommendation:

| Field | Description |
|---|---|
| accountId, agentSpaceRegion, agentSpaceId | Where it came from |
| workloadName | Same label rule as investigations |
| collected_at | The inventory run's time — the only freshness signal, since API timestamps are not stored |
| recommendationId, title, status, priority, taskId | From `ListRecommendations`; `taskId` is the EVALUATION task |

An Agent Space with no current recommendations gets one placeholder line with `recommendationId: none`, which the dataset filters out. It keeps the Agent Space visible in the raw data.

### Collector status record — `collector-status/`

One object per collection stack, overwritten on every inventory run:

| Field | Description |
|---|---|
| accountId, agentSpaceRegion | The collector's account and Region |
| status | `ACTIVE` (Agent Spaces found), `NO_AGENT_SPACES`, or `ERROR` |
| agentSpaceCount, recommendationCount | From this run; `agentSpaceCount` is null if listing failed |
| removedAgentSpaces | Recommendation objects removed because their Agent Space no longer exists |
| lastRunAt, collectorVersion | When, and which version |
| failedEventsPending | Depth of the failed-events queue |
| replicationFailures | Recent objects whose replication status is `FAILED` |
| errorMessage | Errors from this run, if any |

The status record is written before the function raises on an error, so an `ERROR` status is visible even when the run itself is retried. The Coverage dataset marks a collector `STALE` when its `lastRunAt` is more than 5 days old — two missed runs plus margin.

## Storage and Tables

### S3 keys and the primary key

```
investigations-v2/account_id=<account>/region=<agent-space-region>/agentspace_id=<id>/<executionId>.json
recommendations-v1/account_id=<account>/region=<agent-space-region>/agentspace_id=<id>/current.json
collector-status/account_id=<account>/region=<agent-space-region>/status.json
```

`executionId` is the primary key for an investigation: assigned by DevOps Agent, immutable, and never reused. The key is a pure function of four immutable values, so one investigation can only ever produce one object, however many times live capture, backfill, or redrive runs. `region` is safe to include because an Agent Space cannot change Region — the Region is part of its ARN.

Rules for the key:

- **Only immutable identifiers.** A computed value such as a date derived from timestamps, or a changeable one such as the workload label or priority, can differ between two runs. The investigation would then be stored under two keys and counted twice in every metric.
- **Do not change the layout of a running deployment.** A new layout writes new objects beside the old ones; replication does not remove the old ones. If it must change, delete the old prefix in every staging bucket and the dashboard bucket, then backfill.
- **Verify with a query:**
  ```sql
  SELECT executionid, COUNT(*) AS copies
  FROM devops_agent_dashboard.investigations_v2
  WHERE executionid <> ''
  GROUP BY executionid HAVING COUNT(*) > 1;   -- must return zero rows
  ```

The date is not in the key. `investigationDate` and `investigationMonth` are fields in each record, and that is what the dashboard filters on.

### Glue tables are declared, not crawled

The dashboard stack declares three tables with fixed schemas: `investigations_v2`, `recommendations_v1`, and `collector_status`. They use the OpenX JSON SerDe, which matches JSON keys to lower-case column names.

- **The dashboard can be created before any data exists.** A crawler cannot infer a schema from an empty bucket; declared tables exist from the first deployment.
- **The schema is a contract.** A new record field appears in Athena only after it is added to the table definition, so column types never change unexpectedly.
- **No partitions, so no partition registration.** Athena reads every object under a table's `LOCATION` ([Specify a table location](https://docs.aws.amazon.com/athena/latest/ug/tables-location-format.html)), and the account and Region are fields in every record. Records from a new account, Region, or Agent Space are queryable as soon as they replicate, with no crawler run and no partition to add. The `account_id=/region=/agentspace_id=` folders in the key keep objects organized and make the primary key readable; they are not table partitions.
- **Trade-off:** every query reads every record. At DevOps Agent volumes — a few KB per investigation — that is fast and costs a fraction of a cent. A fleet with hundreds of thousands of investigations would benefit from partitioning or SPICE.

Do not name a record field `region` or any other name used as a key folder. If tables are ever partitioned by those folders, a data column with the same name as a partition column makes Athena reject the table ([duplicate columns](https://repost.aws/knowledge-center/athena-hive-invalid-metadata-duplicate)). This is why the field is `agentSpaceRegion`, and the datasets expose it as `region`.

## Multi-Region Design

| Decision | Choice | Reason |
|---|---|---|
| Analytics topology | One dashboard bucket in one analytics Region | QuickSight, Athena, and Glue must share a Region. A bucket per Region would still need one dashboard Region and cross-Region query stitching |
| Collection unit | One collection stack per workload account × Agent Space Region | `ListAgentSpaces` and the EventBridge default bus are Regional |
| Transport | S3 replication, cross-account and cross-Region, into the one bucket | Same push model everywhere; the destination is named by bucket only, so the template is identical in every Region |
| Region identity | The collector's own `AWS_REGION` | That is the Agent Space Region. The investigated resources' Region is not available — `relatedResources` are labels |
| Unique names | Bucket and IAM role names carry the Region | S3 bucket names are global and IAM role names are account-wide. Lambda, EventBridge, SQS, and log group names are Regional |

From [Requirements and considerations for replication](https://docs.aws.amazon.com/AmazonS3/latest/userguide/replication-requirements.html):

- Cross-Region replication carries inter-Region data transfer charges; same-Region replication does not.
- The source account must have both Regions enabled, and the destination account the destination Region. This matters for opt-in Regions.
- Most objects replicate within 15 minutes, though it can take longer ([Troubleshooting replication](https://docs.aws.amazon.com/AmazonS3/latest/userguide/replication-troubleshoot.html)).

## Deployment at Scale

The organization path uses CloudFormation StackSets with service-managed permissions. Constraints that shaped the templates ([service-managed StackSets](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/stacksets-orgs-associate-stackset-with-org.html), [auto-deployment](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/stacksets-orgs-manage-auto-deployment.html), [quotas](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/cloudformation-limits.html)):

- **No transforms or macros.** Service-managed StackSets do not support them, so the collection template uses plain CloudFormation only.
- **Template size.** An inline template body is limited to 51,200 bytes. The collection template stays below it (checked by a unit test), so `--template-body file://` works without an S3 upload.
- **Identical parameters everywhere.** Auto-deployed accounts get the StackSet's default parameter values, not overrides, so the template takes only the dashboard account and bucket, which are the same for every account.
- **No deployment to the management account**, which is also where this solution should not run.
- **Retain on account removal.** The staging bucket is versioned and non-empty, so deleting the stack on removal would fail.

## Inventory Collection and Recommendations

The inventory collector runs every 2 days in each collection stack. It:

1. Lists the Agent Spaces in its account and Region.
2. For each, reads the goal's `lastSuccessfulTaskId` and the recommendations of that task, and writes `current.json`.
3. Deletes the `current.json` of any Agent Space that no longer exists — **only** after a complete, successful listing, so a failed list call can never remove data.
4. Measures replication health and the failed-events queue depth.
5. Writes the status record, then raises if any step failed.

### Why `ListGoals` is needed

Recommendations come from scheduled evaluations of a goal, not from investigations. The service provisions one `ONCALL_REPORT` goal per Agent Space; there is no `CreateGoal`. `ListRecommendations` with only `agentSpaceId` returns every recommendation ever emitted, across all past evaluations — measured on one Agent Space, 6 records where the console showed 3. Filtering on the goal's `lastSuccessfulTaskId` returns exactly the current set. Each weekly re-evaluation re-emits the same advice under new IDs, so without the filter the count would grow every week.

Alternatives were rejected: titles are rewritten in place, provenance fields are present on some records and absent on others, and the timestamp fields disagree about which of a pair is newer.

### One object per Agent Space, overwritten

A fixed key per Agent Space means the table always equals current state, with no deduplication logic. The consequence is no history: "how many recommendations were open in June" is not answerable. This is intentional.

### Observed behaviors

- **Status churn.** Records were observed moving `PROPOSED` → `UPDATE_IN_PROGRESS` → `PROPOSED`, with a title rewritten, within 50 minutes. A poll may catch mid-rewrite content; the next poll corrects it. No terminal status (`ACCEPTED`, `REJECTED`) has been observed, so the sheet does not compute acceptance rates.
- **Pagination.** `ListRecommendations` takes `limit` (maximum 100) and `nextToken`; the collector follows `nextToken` explicitly.
- **Excluded fields.** `content.summary` is a JSON-encoded string of 7–14 KB whose inner fields vary between records; it is not stored. `category` and `affected_incidents` live inside it.

## QuickSight Datasets

All five are `DIRECT_QUERY` custom SQL on Athena, created by `scripts/setup-dashboard.sh`.

| Dataset ID | Source | Purpose |
|---|---|---|
| devops-agent-v2 | `investigations_v2`, completed only | KPIs, trends, the investigation list |
| devops-agent-v2-resources | `UNNEST(relatedresources)`, completed only | Resource hotspots |
| devops-agent-v2-details | `UNION ALL` of root cause, causes, symptoms, gaps, resources, completed only | The findings pivot |
| devops-agent-v2-recommendations | `recommendations_v1`, placeholder rows removed | Recommendation status, counts, freshness |
| devops-agent-v2-coverage | `collector_status` joined to per-collector counts of failed and timed-out investigations | The Coverage table |

Every dataset exposes `accountid` and `region` under the same names. The shared Account and Region filters use `CrossDataset: ALL_DATASETS`, which applies a filter to every dataset with a column of the same name, so one filter bar slices every sheet, including Coverage.

The details dataset carries a `recordtype` with a numeric prefix (`1_root_cause` … `5_resource`) so the findings pivot sorts in reading order.

Setup also creates and publishes a **dashboard** from the same definition. Updating a dashboard creates a new version that is not live until published ([UpdateDashboard](https://docs.aws.amazon.com/cli/v1/reference/quicksight/update-dashboard.html)), so the script publishes the latest version explicitly.

## Deployment Notes

- **The Lambda code is inline** in `collection-stack.yaml` and that is the only copy. A separate `.py` file would drift from what CloudFormation deploys. `tests/` extracts the inline code and runs it against in-memory fakes of S3, SQS, and DevOps Agent: `python3 -m unittest discover -s tests -v`.
- **Runtime.** Both functions use `python3.14`, the newest generally available Python runtime on [Lambda runtimes](https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html), and the AWS SDK bundled with it.
- **cfn-lint.** Older releases do not yet know the `aidevops` IAM prefix (W3037) or `python3.14` (E3030). Both are valid; run `cfn-lint -i E3030 W3037 -- <template>` until your version catches up.


---

# Deployment and Operations

> Moved here from the README on 2026-10-28 to keep the README focused on understanding and deploying the solution. This covers post-deploy validation, day-2 operation, failure recovery, what the records contain, the FAQ, troubleshooting, and cleanup.

## Validation

1. **Coverage.** Open the dashboard. The Coverage table at the bottom of Overview lists one row per deployed collector. After backfill (Step 4), or after a collector's first scheduled run (within 2 days), each row shows `ACTIVE` (Agent Spaces found) or `NO_AGENT_SPACES` (idle). Any `ERROR` or `STALE` row: see [Failures and Recovery](#failures-and-recovery).
2. **Live capture.** Run an investigation in an Agent Space. Within minutes, check the staging bucket in that account and Region:
   ```bash
   aws s3 ls "s3://devops-agent-collection-<account-id>-<region>/investigations-v2/" --recursive --region <region>
   ```
   Keys have the form `investigations-v2/account_id=<id>/region=<region>/agentspace_id=<id>/<executionId>.json`.
3. **Replication.** Confirm the object replicated:
   ```bash
   aws s3api head-object --bucket "devops-agent-collection-<account-id>-<region>" \
     --key "<key-from-step-2>" --query ReplicationStatus --region <region>
   ```
   `COMPLETED` is success, `PENDING` means wait (most objects replicate within 15 minutes; see [S3 replication troubleshooting](https://docs.aws.amazon.com/AmazonS3/latest/userguide/replication-troubleshoot.html)), and `FAILED` is covered in [Failures and Recovery](#failures-and-recovery).
4. **Athena**, in the dashboard account:
   ```sql
   SELECT accountid, agentspaceregion, workloadname, status, COUNT(*) AS investigations
   FROM devops_agent_dashboard.investigations_v2
   GROUP BY 1, 2, 3, 4;
   ```
5. **No double counting.** This must return zero rows. Any row is one investigation stored more than once:
   ```sql
   SELECT executionid, COUNT(*) AS copies
   FROM devops_agent_dashboard.investigations_v2
   WHERE executionid <> ''
   GROUP BY executionid
   HAVING COUNT(*) > 1;
   ```

## Running the Guidance

### Normal operation

- EventBridge invokes the investigation collector when an investigation completes, fails, or times out.
- The inventory collector runs every 2 days in each collector. It refreshes the recommendations of every Agent Space and writes the collector's status record.
- S3 replication delivers each object to the dashboard bucket, usually within minutes.
- QuickSight queries Athena at view time. There is no crawler, refresh schedule, or SPICE ingestion to manage.

### What happens when things change

| Change | What happens | Action needed |
|---|---|---|
| New Agent Space in an account and Region that has a collector | Its investigations are captured live; its recommendations and Coverage count appear at the next inventory run | None |
| Agent Space deleted | Its past investigations stay. Its recommendations are removed at the next inventory run | None |
| Agent Space re-tagged or renamed | New records use the new label. Existing records keep the old one | Run `backfill.sh` to relabel history |
| New account joins a targeted OU (organization path) | StackSets auto-deployment creates its collection stack | Run `backfill.sh` only if it already had DevOps Agent history |
| New account (standalone path) | Nothing, until you deploy | Add it to `WorkloadAccountIds` on the dashboard stack, deploy Step 3b, and backfill if it had history |
| New Region adopted | Nothing, until a collector exists there | Add the Region to the StackSet (`create-stack-instances --regions <new-region>`) or deploy Step 3b there |
| Account removed from a targeted OU, or closed | The retained collector stops being able to replicate; its Coverage row turns `STALE` after 5 days. Past data stays in the dashboard | Delete the retained stack if the account remains in use elsewhere |
| New template version | Update the StackSet (`update-stack-set`); the change rolls to every stack instance | Coverage shows each collector's version, so you can see rollout progress |

### Keeping the data correct: one record per investigation

Every metric assumes each investigation is stored exactly once. The S3 key guarantees it, because it is built only from identifiers that never change:

```
investigations-v2/account_id=<account>/region=<agent-space-region>/agentspace_id=<id>/<executionId>.json
```

Live capture, backfill, and redrive all write the same key for the same investigation, so any repeat overwrites in place. **Do not change this key layout**, and do not add a computed or changeable value to it — a date, the workload label, a priority. Two runs that derive such a value differently would store one investigation twice and double-count it in every total, rate, and average.

- Run the duplicate check ([Validation](#validation), step 5) after any bulk backfill.
- If you ever change the layout, delete the old prefix from every staging bucket **and** the dashboard bucket, following [Cleanup](#cleanup), before backfilling again. Replication does not remove objects written under old keys.
- S3 versioning does not cause double counting. Athena reads only current object versions.

## Failures and Recovery

Every failure the solution can detect is surfaced in one place — the **Coverage table** on the Overview sheet — and the repair is almost always the same: fix the cause, then run `scripts/backfill.sh` (idempotent) or `scripts/redrive.sh` in that account and Region.

The Coverage table has one row per collector (account × Region):

| Column | Meaning |
|---|---|
| Health | `ACTIVE` — Agent Spaces found · `NO_AGENT_SPACES` — idle · `ERROR` — the last inventory run failed (see *Last error*) · `STALE` — no status for more than 5 days |
| Failed events pending | Events in the collector's failed-events queue (`devops-agent-failed-events`) |
| Replication failures | Recent objects in the staging bucket whose replication status is `FAILED` |
| Failed / timed-out investigations | Investigations DevOps Agent itself reported as failed or timed out |

| Failure | How you see it | How you fix it |
|---|---|---|
| Stack instance fails to deploy (opt-in Region disabled, service control policy, name collision) | StackSet operation status; `list-stack-instances` | Fix the cause, then `update-stack-instances` or re-run `create-stack-instances` for that account and Region |
| DevOps Agent or S3 API throttling | Absorbed: both functions use the SDK's adaptive retry mode | None |
| Investigation collector fails on an event (bug, permissions, API error) | Lambda retries twice; then the event is kept in the failed-events queue — *Failed events pending* > 0 | Fix the cause, then `bash scripts/redrive.sh <region>` in that account |
| EventBridge cannot invoke a collector | The event goes to the same failed-events queue | Same as above |
| Inventory run fails | Health `ERROR` with *Last error*; the run also goes to the failed-events queue | Fix the cause; `redrive.sh` or wait for the next run |
| Replication fails (account not allowed by the dashboard bucket policy, opt-in Region not enabled) | *Replication failures* > 0; `head-object` shows `FAILED` | Fix the bucket policy or Region, then run `backfill.sh` — rewriting creates new object versions, which replicate |
| Collector stopped, deleted, or its account closed | Health `STALE` | Redeploy the stack instance, or remove the row's cause |
| Agent Space in a Region with no collector | Organization path: prevented by targeting every Region where DevOps Agent is available. Standalone path: not visible | Deploy the collection stack in that Region, then run `backfill.sh` |
| Investigation completed but has no summary (journal aged out) | `backfill.sh` reports `SKIP`; live capture keeps the event in the failed-events queue | Not recoverable — the source data no longer exists |
| QuickSight setup fails | `setup-dashboard.sh` prints the analysis or dashboard errors and exits non-zero | Fix, then re-run (idempotent) |
| Duplicate records | Duplicate check ([Validation](#validation) step 5) returns rows | Remove the prefix written under the wrong layout, then run `backfill.sh` |

`redrive.sh` deletes a message only after its replay succeeds; a message that fails again stays in the queue. The queue keeps messages for 14 days, the SQS maximum. After that, `backfill.sh` still recovers any completed investigation, because it re-reads everything from DevOps Agent.

## What the collected records contain

Investigation records hold investigation **metadata** and agent-written **narrative text**: symptom titles, the root-cause title and description, contributing causes, investigation gaps, and the labels the agent used for the resources it examined. They do not contain application payloads, log contents, or metric data.

- **`rootCauseDescription` is free-form agent narrative** and can be long. It describes your infrastructure and what was misconfigured. Treat it like an incident write-up.
- **`relatedResources` are the agent's own labels, not ARNs** (for example, `Workload Table`). They are meaningful only within the workload that produced them.
- **Every dashboard reader sees every account's data.** Reader-level row security by account or workload is not configured.

Full detail: [Permissions Model](#permissions-model).

## FAQ

**Q: Which stack do I deploy first?**
A: The dashboard stack. Collection stacks configure replication into its bucket, and S3 rejects a replication destination that does not exist.

**Q: Do I need AWS Organizations?**
A: No. The standalone path works with any set of accounts. Organizations makes large deployments easier: StackSets deploys the collection stack everywhere, and the bucket policy trusts the organization instead of a list you maintain.

**Q: Do I need to deploy a collector in every Region where my workloads run?**
A: No — only in Regions that hold Agent Spaces. An Agent Space monitors its accounts' resources in every Region ([Supported Regions](https://docs.aws.amazon.com/devopsagent/latest/userguide/about-aws-devops-agent-supported-regions.html)).

**Q: What do the account and Region columns mean?**
A: The account and Region of the **Agent Space** that ran the investigation. Under the [supported Agent Space model](../README.md#does-this-fit-your-setup) that is also the workload's account. It is not necessarily the Region of the investigated resources.

**Q: I deployed collectors in accounts that don't use DevOps Agent. Is that a problem?**
A: No. Those collectors report `NO_AGENT_SPACES` in the Coverage table and cost almost nothing. They start collecting as soon as an Agent Space is created.

**Q: When do I need to run the backfill?**
A: Once, for accounts that had DevOps Agent history before their collection stack existed. Also as the repair step after fixing a failure, or after re-tagging Agent Spaces. It is always safe to re-run.

**Q: Why do investigation metrics exclude failed and timed-out investigations?**
A: Resolution rate, time to RCA, and cost describe investigations that produced a result. Failed and timed-out investigations have no findings or duration; counting them would distort every rate. They are recorded, and counted per collector in the Coverage table.

**Q: What does `resolved` mean?**
A: `true` when the investigation summary contains a finding of type `root_cause`. It describes the agent's output, not whether the incident was fixed.

**Q: Is the time-to-RCA figure stable if an investigation is revisited later?**
A: Yes. It is computed from journal records only — the earliest record to the `investigation_summary` record. Journal records are append-only, so the value is fixed once the RCA exists. See [Time to RCA](#time-to-rca--stability-guarantee).

**Q: How fresh is the data?**
A: Investigations appear once replication completes, usually within minutes. Recommendations and Coverage refresh every 2 days. DevOps Agent re-evaluates recommendations weekly.

**Q: Can I change the 60-minute manual baseline for hours saved?**
A: Yes. The Cost & Recommendations sheet has a **baseline slider** (15–240 minutes). Investigations slower than the baseline contribute zero, not a negative number.

**Q: What's the agent cost calculation?**
A: `durationMinutes × 60 × $0.0083`, the published [per-agent-second rate](https://aws.amazon.com/devops-agent/pricing/). It is a list-rate estimate from the journal-record duration, not billing data, and ignores AWS Support plan credits.

**Q: Why don't recommendations show history or acceptance rates?**
A: The inventory collector keeps one current object per Agent Space, so the sheet always shows what the agent recommends now. Recommendation status also changes back and forth during evaluation. See [Inventory Collection and Recommendations](#inventory-collection-and-recommendations).

**Q: The stack failed with `InsufficientCapabilitiesException`.**
A: Both stacks create IAM roles with explicit names, which requires `CAPABILITY_NAMED_IAM`.

## Troubleshooting

### A Coverage row is `ERROR`

Read *Last error*. Common causes: DevOps Agent is not available in that Region (remove the Region from the StackSet), or a service control policy denies one of the collector's actions. After fixing it, run `bash scripts/redrive.sh <region>` in that account, or wait for the next run.

### *Failed events pending* is above zero

Open the investigation collector's CloudWatch Logs (`/aws/lambda/devops-agent-investigation-collector`) in that account and Region, fix the cause, then run `bash scripts/redrive.sh <region>`. Use `--dry-run` first to see what will be replayed.

### *Replication failures* is above zero

The object was written to the staging bucket, but its `ReplicationStatus` is `FAILED`, so it never reaches the dashboard. Check the dashboard bucket policy allows that account — with `OrganizationIds`, the account must be in the organization; with `WorkloadAccountIds`, it must be listed. For a cross-Region collector, check that both accounts have enabled the Region. Then run `bash scripts/backfill.sh <region>` in that account.

### The collection stack went in first and nothing replicates

The dashboard bucket is the replication destination, so it must exist before any collection stack writes to it. If a collection stack was deployed before the dashboard stack, deploy the dashboard stack, then run `bash scripts/backfill.sh <region>` in that account to replay the objects into it.

### An account or Region is missing from the Coverage table

No collection stack exists there, or its first inventory run has not happened yet (within 2 days of deployment). Check the stack instance status, or run `backfill.sh`, which triggers an inventory run immediately.

### Coverage shows `NO_AGENT_SPACES` but the account has an Agent Space

The account's investigations still flow and appear live — only the Coverage row and recommendations lag, because they refresh on the inventory collector's 2-day schedule, not on investigation events. This happens when an Agent Space is created (or deleted) after the last inventory run. It corrects itself at the next scheduled run; to update it now, invoke the inventory collector once in that account and Region:

```bash
aws lambda invoke --function-name devops-agent-inventory-collector --region <region> /dev/stdout
```

(`backfill.sh` does this too, at the end of its run.)

### Collection stack fails with `LogGroup already exists`

A previous, rolled-back deployment left the log group behind. Delete it, then retry:

```bash
aws logs delete-log-group --log-group-name /aws/lambda/devops-agent-investigation-collector --region <region>
aws logs delete-log-group --log-group-name /aws/lambda/devops-agent-inventory-collector --region <region>
```

### Deployment fails right away, before any data flows

This is almost always a missing prerequisite, and the error names which one:

- **StackSets trusted access not activated** — the StackSet calls fail. Activate trusted access with AWS Organizations.
- **QuickSight not enabled, or its service role is not named `aws-quicksight-service-role-v0`** — `setup-dashboard.sh` fails. Enable QuickSight Enterprise edition in the analytics Region and use the default service-role name.
- **An Agent Space Region not opted in** for both the workload and dashboard accounts — only that one Region's instance fails; failure tolerance lets the rest proceed. Enable the opt-in Region in both accounts, then redeploy that instance.

### The follow-up queue on the Investigations sheet is empty

That is the healthy state. The queue lists investigations that were unresolved, or that used over 80% of the context window with a compaction. If every investigation reached a root cause without exhausting its context, there is nothing to list.

## Cleanup

### 1. QuickSight resources

Delete the QuickSight objects created by `setup-dashboard.sh`, in this order. Delete the **published dashboard first**: it is a separate object from its analysis, and removing the analysis/datasets first would leave readers with a dashboard whose every visual errors. You can also delete these from the QuickSight console (Dashboards → Analyses → Datasets → Data sources).

```bash
ACCT=<dashboard-account-id>; REGION="${ANALYTICS_REGION}"

aws quicksight delete-dashboard  --aws-account-id "$ACCT" --dashboard-id devops-agent-operations-dashboard --region "$REGION"
aws quicksight delete-analysis   --aws-account-id "$ACCT" --analysis-id devops-agent-operations-dashboard --force-delete-without-recovery --region "$REGION"
for DS in devops-agent-v2 devops-agent-v2-resources devops-agent-v2-details devops-agent-v2-recommendations devops-agent-v2-coverage; do
  aws quicksight delete-data-set --aws-account-id "$ACCT" --data-set-id "$DS" --region "$REGION"
done
aws quicksight delete-data-source --aws-account-id "$ACCT" --data-source-id devops-agent-athena-ds --region "$REGION"
```

### 2. Empty the buckets — safely

All buckets are versioned. **Never empty a staging bucket with `aws s3 rm`.** Without version IDs, `rm` writes delete markers, and delete-marker replication is on, so those markers replicate and hide the same records in the dashboard. Delete object versions explicitly instead (deletes of specific versions are not replicated). The S3 console's **Empty bucket** action also deletes all versions.

```bash
# Deletes every version and delete marker, then the bucket.
# Repeat the delete-objects call if a bucket holds more than 1,000 versions.
purge_bucket() {
  local bucket=$1 region=$2
  aws s3api delete-objects --bucket "${bucket}" --region "${region}" --delete "$(
    aws s3api list-object-versions --bucket "${bucket}" --region "${region}" --output json \
      --query '{Objects: [Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers[].{Key:Key,VersionId:VersionId}][]}'
  )"
}
```

### 3. Collection stacks

- **Organization path:** `aws cloudformation delete-stack-instances --stack-set-name devops-agent-collection --deployment-targets OrganizationalUnitIds=<ou-ids> --regions <regions> --no-retain-stacks`, then `delete-stack-set`. Empty each staging bucket first, or the stack deletion fails on the non-empty bucket.
- **Standalone path:** in each account and Region, `purge_bucket devops-agent-collection-<account-id>-<region> <region>`, then `aws cloudformation delete-stack --stack-name devops-agent-collection --region <region>`.

> The staging bucket's `DeletionPolicy` is `Delete`, so deleting a stack whose versioned bucket still holds objects stops at `DELETE_FAILED` — empty the bucket first (above). Removing an account from the organization does **not** hit this: the StackSet sets `RetainStacksOnAccountRemoval=true`, so a removed account keeps its stack and bucket instead of triggering a failed delete.

### 4. Dashboard stack

```bash
purge_bucket "devops-agent-dashboard-<dashboard-account-id>" "${ANALYTICS_REGION}"
purge_bucket "devops-agent-athena-results-<dashboard-account-id>" "${ANALYTICS_REGION}"
aws cloudformation delete-stack --stack-name devops-agent-dashboard --region "${ANALYTICS_REGION}"
```
