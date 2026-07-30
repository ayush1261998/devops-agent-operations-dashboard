# Implementation Guide

## Permissions Model

The solution is read-only against DevOps Agent and uses a push-based data path. No component ever assumes a role into another account, and no component holds write access to DevOps Agent.

### Trust Boundaries

```
┌─ Workload Account ────────────────────────────────┐
│                                                   │
│  Collector Lambda ──reads──▶ DevOps Agent API     │
│         │                    (same account only)  │
│         └──writes──▶ Local S3 collection bucket   │
│                              │                    │
│  Replication Role ───────────┘                    │
│         │                                         │
└─────────┼─────────────────────────────────────────┘
          │ push (S3 replication, no role assumption)
          ▼
┌─ Dashboard Account ───────────────────────────────┐
│  Centralized S3 bucket                            │
│  (authorizes by aws:PrincipalAccount condition)   │
│         │                                         │
│  Glue Crawler ──reads──┘                          │
│  QuickSight ──reads──▶ Athena ──▶ Glue ──▶ S3     │
└───────────────────────────────────────────────────┘
```

The dashboard account has **no** inbound permissions into workload accounts. Data arrives by replication; the dashboard side never initiates a cross-account call. This means compromising the dashboard account grants no access to workload accounts.

### Workload Account — Collector Lambda Role

All DevOps Agent actions are Read or List access level. There are no Write actions.

| IAM Action | Access level | Resource scope | Why needed |
|---|---|---|---|
| `aidevops:ListAgentSpaces` | List | `*` (no resource type defined) | Backfill discovery |
| `aidevops:GetAgentSpace` | Read | `agentspace/*` | Read the `workload` tag |
| `aidevops:ListJournalRecords` | List | `agentspace/*` | Read investigation summary + utilization |
| `aidevops:ListExecutions` | List | `agentspace/*` | Backfill discovery |
| `aidevops:ListBacklogTasks` | List | `agentspace/*` | Backfill discovery |
| `s3:PutObject` | Write | `devops-agent-collection-<account>-<region>/*` | Write collected records |

`ListAgentSpaces` is scoped to `*` because the [Service Authorization Reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_devops-agent.html) defines no resource type for it. Every other action is scoped to `arn:aws:aidevops:<region>:<account>:agentspace/*`.

DevOps Agent does expose `aws:ResourceTag/${TagKey}` as a condition key on the `agentspace` resource type, so it is technically possible to restrict the collector to AgentSpaces already carrying a `workload` tag. **This is not recommended.** An untagged AgentSpace currently still gets collected and lands with `workloadName=unknown`, which surfaces the tagging gap so you can fix it. Tag-gating the collector would make those investigations silently absent instead of visibly mislabeled — trading a self-announcing problem for a silent one. It would also need to be omitted from `ListAgentSpaces` (no resource type, so a resource-tag condition there evaluates false and denies the call), leaving an inconsistent policy for no real gain.

### Workload Account — S3 Replication Role
Standard S3 replication permissions, assumed by `s3.amazonaws.com`:

| IAM Action | Resource |
|---|---|
| `s3:GetReplicationConfiguration`, `s3:ListBucket` | Source bucket |
| `s3:GetObjectVersionForReplication`, `s3:GetObjectVersionAcl`, `s3:GetObjectVersionTagging` | Source bucket objects |
| `s3:ReplicateObject`, `s3:ReplicateDelete`, `s3:ObjectOwnerOverrideToBucketOwner` | Destination bucket objects |

`ObjectOwnerOverrideToBucketOwner` pairs with `AccessControlTranslation: Owner: Destination` in the replication rule, so replicated objects are owned by the dashboard account rather than the source account. Without it, the Glue crawler in the dashboard account cannot read objects it does not own.

#### Replication rules must use the V2 schema fields

Because the rule uses `Filter`, it is on S3's V2 replication schema, which requires `Priority` and `DeleteMarkerReplication` to be stated explicitly. Omitting them fails the stack with:

```
Priority must be specified for this version of Cross Region Replication
configuration schema (Service: S3, Status Code: 400)
```

This surfaces on the **first** deploy, so it is not something a customer can work around. The template sets both:

```yaml
- Id: ReplicateInvestigations
  Status: Enabled
  Priority: 1
  Filter:
    Prefix: "investigations-v2/"
  DeleteMarkerReplication:
    Status: Enabled
```

`DeleteMarkerReplication: Enabled` means removing a record at the source also removes it from the dashboard account, keeping the two in agreement. With it disabled, deleting source data leaves orphaned rows in the dashboard that no longer exist upstream.

### Dashboard Account — Bucket Policy
Authorization is by **account ID condition**, not by named role ARN:

```yaml
- Sid: AllowReplicationFromWorkloadAccounts
  Effect: Allow
  Principal: "*"
  Action: [s3:ReplicateObject, s3:ReplicateDelete, s3:ObjectOwnerOverrideToBucketOwner]
  Resource: !Sub "${DashboardBucket.Arn}/*"
  Condition:
    StringEquals:
      aws:PrincipalAccount: !Ref WorkloadAccountIds
```

This is deliberate and load-bearing for deployment order. Naming the replication role ARN directly (`arn:aws:iam::<workload>:role/devops-agent-replication-role-<workload>`) would fail policy validation with `Invalid principal in policy`, because that role does not exist yet when the dashboard stack deploys. Using `Principal: "*"` narrowed by `aws:PrincipalAccount` is equivalently restrictive — only principals in the listed accounts match — while removing the ordering constraint.

`Principal: "*"` without the condition would be public. The condition is not optional.

### Dashboard Account — Glue Crawler Role

| IAM Action | Resource |
|---|---|
| `s3:GetObject`, `s3:ListBucket` | Centralized bucket |
| `glue:*Table`, `glue:*Partition`, `glue:GetDatabase` | Solution's Glue database only |
| `logs:CreateLogGroup`, `logs:PutLogEvents` | `/aws-glue/crawlers*` |

### Dashboard Account — QuickSight Service Role

| IAM Action | Resource |
|---|---|
| `athena:StartQueryExecution`, `athena:GetQueryResults`, `athena:GetQueryExecution` | Athena workgroup |
| `glue:GetTable`, `glue:GetPartitions`, `glue:GetDatabase` | Solution's Glue database |
| `s3:GetObject`, `s3:ListBucket` | Centralized bucket |
| `s3:PutObject` | Athena query results bucket |

### Deployer Permissions

The human or pipeline running deployment needs:

| Step | Account | Required |
|---|---|---|
| 1 | Dashboard | CloudFormation + `iam:CreateRole`, `iam:PutRolePolicy`, S3, Glue, QuickSight admin |
| 2 | Each workload | CloudFormation + `iam:CreateRole`, `iam:PutRolePolicy`, S3, Lambda, EventBridge |
| 3 | Dashboard | QuickSight author (`quicksight:CreateDataSet`, `CreateAnalysis`, `CreateDataSource`) |
| 4 | Each workload | `lambda:InvokeFunction` + the `aidevops` read actions above |

No step requires organization-level or management-account access. This solution does not use CloudFormation StackSets or AWS Organizations trusted access.

## Historical Backfill

### The Gap

EventBridge rules only match events emitted after the rule exists. Investigations that completed before Step 2 produce no S3 record and are absent from the dashboard.

### Discovery Chain

Two calls per AgentSpace. [`ListBacklogTasks`](https://docs.aws.amazon.com/devopsagent/latest/APIReference/API_ListBacklogTasks.html) already carries everything the collector needs, so `ListExecutions` is not required for investigation backfill:

```
ListAgentSpaces                       -> agentSpaceId[]
  └─ ListBacklogTasks(agentSpaceId)   -> taskId, executionId, taskType,
                                         priority, status, createdAt, updatedAt
       └─ (invoke collector Lambda)
```

Verified response shapes:

```jsonc
// ListAgentSpaces - note: NO tags field, hence the separate GetAgentSpace call
{"agentSpaces": [{"name": "...", "agentSpaceId": "...", "createdAt": "...", "updatedAt": "..."}]}

// ListBacklogTasks
{"tasks": [{
  "agentSpaceId": "...", "taskId": "...", "executionId": "...",
  "title": "Investigation 2026-01-07T16:54:26.450Z",
  "taskType": "INVESTIGATION",     // also: SYSTEM_LEARNING, EVALUATION
  "priority": "MEDIUM",            // CRITICAL|HIGH|MEDIUM|LOW|MINIMAL
  "status":   "COMPLETED",
  "createdAt": "...", "updatedAt": "...", "version": 3, "hasLinkedTasks": false
}]}
```

Only tasks with `taskType == INVESTIGATION` and `status == COMPLETED` are replayed. In one observed AgentSpace, 2 of 3 tasks were `SYSTEM_LEARNING` / `EVALUATION` — filtering avoids invoking the collector on tasks that can never produce an investigation summary.

### Task Status vs Execution Status

**These are different fields with different semantics, and only the task-level one indicates success.**

Observed on the same successfully-completed unit of work:

| Level | Field | Value |
|---|---|---|
| Task (`ListBacklogTasks`) | `status` | `COMPLETED` |
| Execution (`ListExecutions`) | `executionStatus` | **`STOPPED`** |

The `Execution.executionStatus` enum is `FAILED | RUNNING | STOPPED | CANCELED | TIMED_OUT` — it has **no success value at all**. A successful execution reports `STOPPED`, meaning the process stopped. Filtering executions for `COMPLETED` matches zero rows.

Note also that the two enums spell cancellation differently: `CANCELED` (one L) in the Execution enum, `CANCELLED` (two Ls) in the EventBridge `data.status` enum.

Use the task's `status` field. The backfill script does.

### One Task Has Multiple Executions

An `INVESTIGATION` task carries more than one execution. Observed:

| executionId | agentSubTask | agentType | Role |
|---|---|---|---|
| `af86bb06…` | `oncall` | `ops1` | the investigation itself |
| `f69fefe9…` | `task-chat` | `taskChat` | chat session, no summary record |

`agentType: ops1` is the investigation agent — which is why collected execution IDs carry an `exe-ops1-` prefix.

The task's own `executionId` field points at the `ops1` execution, not the chat one. Reading it directly avoids enumerating executions and filtering out chat noise.

Per the [events detail reference](https://docs.aws.amazon.com/devopsagent/latest/userguide/integrating-devops-agent-into-event-driven-applications-using-amazon-eventbridge-devops-agent-events-detail-reference.html), a mitigation is a further execution under the same `taskId`:

```
task_id: a1b2c3d4-...-example11111
  ├─ execution_id: b2c3d4e5-...-example22222   (Investigation Completed)
  └─ execution_id: c3d4e5f6-...-example33333   (Mitigation Completed)
```

So mitigations are reachable via `ListExecutions` on an investigation task. `task_type` cannot distinguish them — the docs specify `INVESTIGATION` for mitigation events too. Use `agentSubTask` / `agentType`.

### Timestamp Normalization

Different DevOps Agent APIs have been observed rendering the same instant differently through the CLI:

```
ListBacklogTasks -> 2026-01-07T17:02:44.592000+00:00   (UTC)
ListExecutions   -> 2026-01-07T10:54:47-06:00          (local offset)
```

Truncating to the first 19 characters and appending `Z` is therefore unsafe — a local-offset timestamp would be mislabelled as UTC, shifting it by the offset and corrupting both `durationMinutes` and the S3 date partition, with no error raised. The script strips fractional seconds, preserves the offset, and parses it explicitly. Rendering is also affected by the `cli_timestamp_format` setting, so this cannot be assumed stable across environments.

### Why a Synthetic EventBridge Event

The collector Lambda's input contract is an EventBridge event. Backfill constructs an event matching that shape and invokes the Lambda directly, rather than reimplementing collection logic in the script.

This keeps one implementation of the journal parsing, the MTTR calculation, the cost formula, and the S3 key derivation. A standalone backfill writer would be a second copy of that logic and would drift — historical rows would silently stop matching live rows after the next Lambda change. Reusing the Lambda makes backfilled and live rows byte-identical in structure by construction.

Idempotency makes this safe to re-run: the S3 key is derived from `executionId` plus the investigation date, so repeat runs overwrite in place instead of duplicating.

### Field Sources for the Synthetic Event

`ListBacklogTasks` supplies every field the event needs. Two are easy to get wrong:

- **`priority`** must be read from the task record (`CRITICAL|HIGH|MEDIUM|LOW|MINIMAL`). Substituting a default silently mislabels every backfilled row, and because the dashboard groups by priority the error is invisible in the data but visible in the charts.
- **`updatedAt`** on a completed task is the completion time. The live path uses the EventBridge event `time` — when the event was *emitted*, normally within seconds but not guaranteed identical.

### Running It

```bash
# Preview without writing anything
bash scripts/backfill-historical.sh us-east-1 --dry-run

# Execute
bash scripts/backfill-historical.sh us-east-1
```

Run it in each workload account after the collection stack is deployed. Then run the Glue crawler in the dashboard account.

### Limitations

| Limitation | Detail |
|---|---|
| Journal retention | Backfill recovers only what DevOps Agent still retains. Tasks whose journal records have aged out return "no investigation_summary" and are skipped. |
| Untagged AgentSpaces | Records are still created but land with `workloadName=unknown`. Tag the AgentSpace and re-run to correct them in place. |
| Non-investigation tasks | `SYSTEM_LEARNING` and `EVALUATION` tasks are filtered out by design — they produce no investigation summary. |
| Mitigations | Out of scope by design. This solution does not collect mitigation data and deploys no mitigation resources. |
| Throttling | The script sleeps 300 ms between invocations. For very large histories consider running per-AgentSpace. |

### Verified Against Live Data

A `--dry-run` against two AgentSpaces confirmed the walk end to end:

```
AgentSpace 6b6771b2-... (workload=untagged)
  WARNING: no 'workload' tag - rows will show workloadName=unknown.
  WOULD BACKFILL af86bb0691b141e884c5e42f1198bfe6 (priority=MEDIUM, completed 2026-01-07T17:02:44Z)
AgentSpace d6f16d84-... (workload=untagged)
  No completed investigation tasks.

  AgentSpaces scanned:      2
  Investigation tasks:      1
  Backfilled:               1
```

Confirmed: `INVESTIGATION` selected while `SYSTEM_LEARNING` and `EVALUATION` were filtered; the `ops1` execution chosen over the `taskChat` one; real priority read from the task; untagged AgentSpaces warned rather than skipped.

`--dry-run` does not require the collector Lambda to exist, so discovery can be validated before deploying the collection stack.

### Verifying the Backfill

```sql
-- Investigations by month; pre-deployment months confirm backfill worked
SELECT investigationmonth, COUNT(*) AS investigations
FROM devops_agent_dashboard.investigations_v2
GROUP BY investigationmonth
ORDER BY investigationmonth;
```

## Time to RCA — Stability Guarantee

`durationMinutes` is the headline metric, so it must mean the same thing every time it is computed. Both endpoints come from **journal records**, which are append-only and whose `createdAt` never changes:

| Endpoint | Source |
|---|---|
| start | earliest journal record `createdAt` for the execution |
| end | the `investigation_summary` record's `createdAt` — the moment the RCA existed |

`investigationDate` (and therefore the S3 partition) derives from the same end timestamp.

### Why the alternatives were rejected

Four timestamps sit within about three seconds of each other for a single investigation, and choosing badly makes the metric unstable:

```
execution createdAt      16:13:28.744    investigation started
first journal record     16:13:37.019    <- start used
investigation_summary    16:17:39.070    <- end used (RCA produced)
execution updatedAt      16:17:39.852
EventBridge event.time   16:17:42        <- NOT used
```

**`event.time`** is when the completion event was *emitted*. It disagrees with the summary timestamp by a few seconds, so the live path and the backfill path would report different durations for the same investigation — and re-running a backfill would silently change stored numbers. At a midnight boundary the two could even resolve to different `investigationDate` values, producing a **second S3 object for one investigation**.

**`task.updatedAt`** is unusable. It drifts forward on any later activity against the task — generating a mitigation plan, opening a chat, revisiting it. Measured across five real tasks, four had drifted between three hours and nine days after the investigation finished. Using it reported a 4-minute RCA as roughly 13,000 minutes.

**`execution.updatedAt`** is stable, but sits slightly after the summary was written and requires an extra API call. It measures when the execution stopped, not when the RCA became available.

### Consequences

- The metric is **immutable**. Once an investigation produces its summary, its duration is fixed. Mitigations, re-opening, chat activity, and repeated backfills cannot change it.
- Live and backfill are **identical by construction** — the same code derives both endpoints from the same API response, so a backfill invocation does not even need to supply a timestamp.
- Re-running the backfill is a **true no-op** for unchanged investigations: same duration, same date, same S3 key.

A negative duration is clamped to zero and logged; it would indicate journal records out of order, which has not been observed.

## Dataset Schema

The investigation collector Lambda writes flat JSON records with the following schema:

### Investigation Record (`investigations-v2/`)

| Field | Type | Description |
|-------|------|-------------|
| executionId | string | Unique investigation execution ID |
| agentSpaceId | string | AgentSpace identifier |
| workloadName | string | From AgentSpace `workload` tag |
| accountId | string | AWS account ID where investigation ran |
| status | string | COMPLETED |
| priority | string | MEDIUM, HIGH, CRITICAL |
| investigationStartedAt | string | Earliest journal record timestamp |
| investigationCompletedAt | string | EventBridge event time |
| durationMinutes | number | MTTR in minutes |
| investigationDate | string | YYYY-MM-DD |
| investigationMonth | string | YYYY-MM |
| resolved | boolean | True if root_cause finding exists |
| consoleUrl | string | Direct link to DevOps Agent console |
| symptoms | array[string] | Symptom titles |
| rootCause | string | Root cause title |
| rootCauseDescription | string | Detailed root cause narrative |
| causes | array[string] | Contributing cause titles |
| gaps | array[string] | Investigation gap titles |
| relatedResources | array[string] | Affected AWS resources |
| symptomCount | integer | Count of symptoms |
| causeCount | integer | Count of causes |
| gapCount | integer | Count of gaps |
| resourceCount | integer | Count of related resources |
| contextWindowUtilization | number | Context window % used (0-100) |
| compactionCount | integer | Context compaction events (0 = no overflow) |
| subagentsUsed | array[string] | Sub-agent IDs deployed |
| toolsUsed | array[object] | Tools with call counts: `{name, count}` |
| totalToolCalls | integer | Sum of all tool calls |
| subagentCount | integer | Number of sub-agents used |
| agentCostUsd | number | Investigation cost at $0.0083/sec |

### Execution Types Within a Task

`agentType` (and `agentSubTask`, which mirrors it) identifies what each execution did. Values observed live:

| agentType | agentSubTask | Meaning |
|---|---|---|
| `ops1` | `oncall` | The investigation — the only type this solution collects |
| `mitigation` | `mitigation` | A mitigation run, if one was generated |
| `taskChat` | `task-chat` | Chat session; no summary record |
| `systemLearning` | `systemLearning` | AgentSpace understanding build |

A single task can hold several of these. Only the `ops1` execution carries an `investigation_summary` record, which is why it is the one the collector reads:

```
task a3c9b7f1-...
  ├─ exe-ops1-708745b0-...   agentType=ops1        (investigation -- collected)
  └─ 450252b9-...            agentType=mitigation  (not collected)
```

Note the ID formats are not uniform — `exe-ops1-` prefixed, bare UUID, and dashless hex have all been observed. Do not parse execution IDs to infer type; read `agentType`.

## S3 Path Convention and Primary Key

`executionId` is the primary key for an investigation. It is globally unique, assigned by DevOps Agent, immutable, and never reused.

The object key is a pure function of three immutable values:

```
investigations-v2/account_id={accountId}/agentspace_id={agentSpaceId}/{executionId}.json
```

Nothing in the key is computed, so the same investigation can only ever produce one object — regardless of which code version writes it, or how many times the collector or the backfill script runs. Re-running is an overwrite, never an insert.

### Why the date is not in the path

An earlier version partitioned by `year=/month=/day=` derived from the investigation date. That made the key a *compound* key with a computed component, and it produced real duplicates: a backfill run derived the date one way, a later run derived it another, and five investigations ended up stored twice under two different `day=` partitions — double-counted in every dashboard metric.

Deriving the date from immutable journal records makes that unlikely; removing the date from the key makes it impossible. The correctness of the primary key no longer depends on the correctness of the date logic.

### Date filtering is unaffected

`investigationDate` and `investigationMonth` are **columns inside each record**, and that is what the QuickSight datasets read. The path partitions were only ever an Athena pruning optimization. After the change the table partitions on `account_id` and `agentspace_id` — both immutable — and date filtering, month-over-month comparison, and the time-series charts work unchanged.

At this data volume pruning on date saves a negligible amount: a year of 100 investigations/month is a few MB, which Athena scans for a fraction of a cent.

### Deployment note

The collector Lambda source lives **inline in `collection-stack.yaml`** (`CollectorFunction.Code.ZipFile`) and that is the only copy. A standalone `.py` was removed deliberately: it silently diverged from the inline version twice during development, and because CloudFormation deploys the inline copy, a fix applied only to the file would pass review while shipping broken code.

CloudFormation's inline limit is 4 MB for the resulting zip ([AWS::Lambda::Function Code](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-properties-lambda-function-code.html)), verified by deploying this template. Note that `cfn-lint` may still warn about a legacy 4096-character limit; that limit is not enforced by CloudFormation.

## Key Design Decisions

### Single Source of Truth
The `investigation_summary` journal record contains all findings, symptoms, gaps, and resources in one structured object. The Lambda parses this single record rather than assembling data from multiple journal entries.

### Utilization Record Selection
DevOps Agent may produce multiple `utilization` records per execution (progressive updates). The Lambda keeps the record with the **highest context window utilization** — this is the most complete record containing final sub-agent and tool usage data.

### Content Field Handling
The boto3 `list_journal_records` API returns `content` as either a JSON string or a pre-parsed dict depending on the SDK version and record type. The Lambda handles both via `isinstance()` check.

### MTTR Calculation
- **Start time**: Earliest `createdAt` timestamp across all journal records for the execution
- **End time**: EventBridge event `time` field (when the completion event was emitted)

### Agent Cost
Calculated at `$0.0083/second × durationMinutes × 60`. This is the DevOps Agent per-second rate.

### Hours Saved (ROI)
QuickSight calculated field: `(60 - durationminutes) / 60`

The 60-minute baseline represents typical manual RCA time. This is configurable in QuickSight by editing the calculated field or adding a parameter.

## Recommendations Collection (PROPOSED — not yet implemented)

> **Status: design only.** Nothing described in this section is deployed. The
> CloudFormation templates in this repository do **not** create a recommendations
> collector, table, IAM permissions, schedule, or dashboard sheet. This section records an
> agreed design and the live-API research behind it so the reasoning is not lost before the
> code is written. Everything under "Verified against live data" was measured against real
> AgentSpaces; everything else is intent.

A second, independent collector would capture the DevOps Agent's *recommendations* — the
preventative improvements it proposes, shown as "Improvements" in the console. This is
separate from investigation collection in every respect: different trigger (schedule, not
event), different grain (current state, not historical event), different table, different
sheet.

### Where recommendations come from

Recommendations are **not** produced by investigations. They are produced by scheduled
evaluations of a *goal*:

```
Goal  (goalType: ONCALL_REPORT, status: ACTIVE, evaluationSchedule: rate(7 days))
  └─ EVALUATION task   "Scheduled evaluation of goal <goalId>"
       └─ Recommendations
```

Customers do not create goals. The API exposes `list-goals` and `update-goal` but there is
**no `create-goal` or `delete-goal`** — the service provisions one `ONCALL_REPORT` goal per
AgentSpace automatically at creation time. This means recommendations require zero customer
configuration, and every AgentSpace should have them.

A recommendation's `taskId` is the **EVALUATION** task, not an investigation. Joining
recommendations to the investigations table on `taskId` returns zero rows.

### Collection flow

```
list-agent-spaces                                   → agentSpaceId[]
  └─ get-agent-space (tags)                         → workloadName
  └─ list-goals                                     → lastSuccessfulTaskId
       └─ list-recommendations --task-id <lastSuccessfulTaskId>
```

One `list-recommendations` call per AgentSpace is sufficient. `get-recommendation` returns
an identical field set (verified) and adds nothing — do not fan out per recommendation.

### Why `list-goals` is required

`list-recommendations --agent-space-id` alone returns **every emission ever made**, across
all past evaluations. The console shows only the current evaluation. Measured on the
payments AgentSpace:

| Query | Result |
|---|---|
| `--agent-space-id` only | 6 records |
| `--agent-space-id` + `--task-id <lastSuccessfulTaskId>` | **3 records — matches console** |

Each weekly re-evaluation re-emits the same advice with new `recommendationId`s under a new
`taskId` (`provenance.production_method: carried_forward`). Without the filter, the row count
inflates every week and the dashboard disagrees with what the customer sees.

Dedup alternatives were evaluated and rejected:

- **By `title`** — titles are rewritten in place. `rec-b233eba9` changed from "Implement
  scheduled CloudFormation drift detection…" to "Enable AWS Config drift detection…" within
  a 50-minute window, same `recommendationId`. Grouping on title would merge and split rows
  unpredictably.
- **By `provenance.content_producing_execution_ids`** — present on some records, absent on
  others (see Schema variance below). Not dependable.
- **By newest timestamp** — `updatedAt` and `rankedAt` point at *opposite* records as most
  recent within a carried-forward pair.

`lastSuccessfulTaskId` is a documented top-level field and the only sound discriminator.

### S3 key — one object per AgentSpace, overwritten

```
recommendations-v1/account_id={accountId}/agentspace_id={agentSpaceId}/current.json
```

This differs deliberately from the investigations convention (one object per `executionId`).

**Why not one object per `recommendationId`:** filtering the API call does not prevent
accumulation, because S3 never forgets. Week 1 writes 3 objects for task A; week 2 the goal
re-evaluates and writes 3 objects for task B; the table now holds 6 and the original problem
returns one week later. A fixed key per AgentSpace, overwritten each poll, means the table
always equals current state — no accumulation, no dedup logic in the collector or the
dashboard, still fully idempotent.

**Consequence:** there is no history. "How many recommendations were open in June" is not
answerable. This is intentional — the sheet reports what the agent currently recommends.

### Record schema

One record per recommendation, newline-delimited within `current.json`:

| Field | Source | Notes |
|---|---|---|
| `account_id` | Lambda context | partition |
| `agentspace_id` | `list-agent-spaces` | partition |
| `workloadName` | AgentSpace `workload` tag | `unknown` when untagged |
| `collected_at` | Lambda | our own poll timestamp — the only freshness signal, since no API timestamps are stored |
| `recommendationId` | API | stable per emission |
| `title` | API | display; **mutable** |
| `status` | API | see status churn below |
| `priority` | API | `HIGH`/`MEDIUM`/`LOW` |
| `taskId` | API | the EVALUATION task; retained so the current set can be re-derived without re-collection |

### Deliberately excluded

- **`content.summary`** — a JSON-encoded string, 7,444–14,307 characters across observed
  records. Not stored. Extract fields if ever needed; never persist the blob.
- **`affected_incidents`** — the only path from a recommendation back to an investigation,
  but it lives inside `content.summary`. Out of MVP scope; revisit if the investigation link
  is wanted.
- **`category`** (e.g. `PROCESS_AND_GOVERNANCE`, `MONITORING_AND_OBSERVABILITY`) — also
  inside `content.summary`. Highest-value excluded field; the most strategic dimension
  available.
- **`rankPosition`, `goalId`, `rankedAt`, `createdAt`, `updatedAt`, `version`** — dropped for
  MVP simplicity. See the sorting limitation below.

### Schedule

`rate(7 days)`, matching the goal's own `evaluationSchedule`. Polling more often is waste —
the source data only changes weekly.

Because the poll and the evaluation are both weekly but not phase-locked, a poll landing
just before an evaluation leaves the sheet up to ~13 days stale. `collected_at` makes this
visible rather than silent.

### IAM — additional read-only actions

| Action | Resource |
|---|---|
| `aidevops:ListGoals` | `agentspace/*` |
| `aidevops:ListRecommendations` | `agentspace/*` |

`aidevops:ListAgentSpaces` and `aidevops:GetAgentSpace` are already granted for investigation
collection.

**`aidevops:UpdateRecommendation` must never be granted.** It exists in the API. A reporting
dashboard must not be able to accept or reject a recommendation on the customer's behalf.

### S3 replication

The `recommendations-v1/` prefix requires a **second replication rule with its own unique
`Priority`** and an explicit `DeleteMarkerReplication` block. Omitting `Priority` on a
multi-rule V2 replication configuration fails the deploy and rolls the stack back — see
"Replication rules must use the V2 schema fields".

### Observed behaviours and limitations

**Status churn.** `UPDATE_IN_PROGRESS` is a working state, not a settled one. Within one
50-minute window, records moved `PROPOSED` → `UPDATE_IN_PROGRESS` → `PROPOSED`, and one
record's title was rewritten entirely. A poll may capture mid-rewrite content; the next poll
corrects it. Do not build acceptance-rate metrics on status until terminal states
(`ACCEPTED`, `REJECTED`, `CLOSED`, `COMPLETED`) are observed in practice — none have been.

**All priorities are `MEDIUM`.** Every recommendation observed across both AgentSpaces is
`MEDIUM`. With `rankPosition` excluded, the sheet has no meaningful sort key.

**Inner schema varies between records.** Fields inside `content.summary` are not consistent
even within one account:

| Inner field | payments record | order-processing record |
|---|---|---|
| `provenance` | present | **absent** |
| `rank_position`, `ranked_at`, `ranking_skill_hash`, `priority_label` | present | **absent** |
| `merged_recommendations` | **absent** | present (null) |

Any future parsing of `content.summary` must treat every nested field as optional and
degrade gracefully. `alternative_options` entries are also non-uniform — one observed entry
omitted `tradeoffs` and `estimated_effort`.

**`list-recommendations` is not auto-paginated.** Unlike `list-agent-spaces` and
`list-backlog-tasks`, it is not documented as a paginated operation and takes raw `--limit`
(max 100) / `--next-token` rather than `--starting-token`/`--page-size`/`--max-items`. The
CLI will not loop automatically — `nextToken` must be followed explicitly. Observed
responses returned `nextToken: null`, but an AgentSpace with more than 100 recommendations
would silently truncate.

**`lastTaskId` vs `lastSuccessfulTaskId`.** When these diverge, the most recent goal
evaluation failed — a signal available nowhere else. Both matched in all observations, so
the failure path is unverified.

### Verified against live data

| Check | Result |
|---|---|
| `list-recommendations` unfiltered, payments | 6 records, 4 distinct titles, 2 tasks |
| Filtered to `lastSuccessfulTaskId` | 3 records — matches console |
| `list-recommendations` unfiltered, order-processing | 1 record (goal not yet re-evaluated) |
| `get-recommendation` vs list item | identical 13 fields, `content.summary` only |
| Goals per AgentSpace | exactly 1, `ONCALL_REPORT`, `ACTIVE`, `rate(7 days)` |
| `content.spec` | never populated on any observed record |

## EventBridge Event Patterns

### Investigation Completion
```json
{
  "source": ["aws.aidevops"],
  "detail-type": ["Investigation Completed"]
}
```


## API Reference

### DevOps Agent APIs Used

| API | Purpose |
|-----|---------|
| `get_agent_space(agentSpaceId)` | Get AgentSpace tags (workload name) |
| `list_journal_records(agentSpaceId, executionId, limit=100)` | Fetch investigation journal |

### IAM Permissions Required (Lambda)

```json
{
  "Effect": "Allow",
  "Action": [
    "aidevops:GetAgentSpace",
    "aidevops:ListJournalRecords"
  ],
  "Resource": "*"
}
```

## QuickSight Datasets

| Dataset ID | Source | Purpose |
|-----------|--------|---------|
| devops-agent-v2 | Direct SQL on investigations_v2 | Main metrics, KPIs, all scalar fields |
| devops-agent-v2-resources | UNNEST(relatedresources) | Resource-level analysis |
| devops-agent-v2-details | UNION ALL of root_cause/cause/symptom/gap | Cascade pivot view |

## Troubleshooting

### No data in dashboard
1. Check if AgentSpaces are tagged with `workload=<name>`
2. Verify EventBridge rule is enabled: `aws events describe-rule --name devops-agent-investigation-completed`
3. Check Lambda logs: `aws logs tail /aws/lambda/devops-agent-investigation-collector`
4. Verify S3 replication status: check `ReplicationStatus` on source objects
5. Run the Glue crawler manually: `aws glue start-crawler --name devops-agent-crawler-<account-id>`

### Sub-agents/tools showing zero
The Lambda keeps the utilization record with the highest context window value. If all utilization records have empty sub-agent arrays, the investigation may not have used sub-agents (short investigations sometimes don't).

### Negative "hours saved"
If an investigation takes longer than 60 minutes, the hours saved will be negative. Adjust the baseline in the QuickSight calculated field or add a `MAX(0, ...)` wrapper.

### Duplicate records from backfill
The S3 key is deterministic (based on execution ID and investigation date). Re-running the Lambda for the same investigation overwrites the previous record — no duplicates.
