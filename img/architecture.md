# Architecture Diagram

`architecture.png` must be generated from `architecture.svg` in this directory.
The SVG is the source of truth — edit it, then re-export.

## Flow

```
┌───────────────────────────────────────────────────────────────────────┐
│                        Workload Account(s)  1..N                      │
│                                                                       │
│   ┌──────────────┐      ┌───────────────┐      ┌──────────────────┐   │
│   │ DevOps Agent │─────▶│  EventBridge  │─────▶│  Lambda          │   │
│   │ (AgentSpace) │      │  Rule         │      │  Investigation   │   │
│   └──────────────┘      │ "Investigation│      │  Collector       │   │
│          ▲              │   Completed"  │      └────────┬─────────┘   │
│          │              └───────────────┘               │             │
│          │  ListJournalRecords / ListExecutions         │             │
│          └───────────────────────────────────────────────┘             │
│                                                         │             │
│                                                         ▼             │
│                                       ┌───────────────────────────┐   │
│                                       │  S3 Collection Bucket     │   │
│                                       │  (versioned, SSE-S3)      │   │
│                                       │  ...-<account>-<region>   │───┼──┐
│                                       └───────────────────────────┘   │  │
└───────────────────────────────────────────────────────────────────────┘  │
                                                                          │
              S3 Replication  (cross-ACCOUNT, same region)                │
                                                                          │
┌───────────────────────────────────────────────────────────────────────┐  │
│                          Dashboard Account                            │  │
│                                                                       │  │
│   ┌───────────────────────────┐                                       │  │
│   │  S3 Centralized Bucket    │◀──────────────────────────────────────┼──┘
│   │  (SSE-S3, 3-yr retention) │                                       │
│   └─────────────┬─────────────┘                                       │
│                 ▼                                                     │
│   ┌───────────────────────────┐    ┌───────────────────────────────┐  │
│   │  AWS Glue Crawler         │───▶│  Glue Data Catalog            │  │
│   │  (every 30 min)           │    │  investigations_v2            │  │
│   └───────────────────────────┘    │  part: account_id,            │  │
│                                    │        agentspace_id          │  │
│                                    └───────────────┬───────────────┘  │
│                                                    ▼                  │
│                                    ┌───────────────────────────────┐  │
│                                    │  Amazon Athena                │  │
│                                    └───────────────┬───────────────┘  │
│                                                    ▼                  │
│                                    ┌───────────────────────────────┐  │
│                                    │  Amazon QuickSight            │  │
│                                    │  4-sheet analysis             │  │
│                                    └───────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────────┘
```

## Notes for whoever regenerates this

- Replication is **cross-account, same-region** — not cross-region. Earlier drafts of this
  diagram said "Cross-Region Replication", which was wrong.
- There is **no mitigation collector**. Mitigation tracking was removed from scope; earlier
  drafts showed a second Lambda and EventBridge rule that do not exist in the templates.
- The Lambda calls back into the DevOps Agent API (`ListJournalRecords`, `ListExecutions`)
  to derive Time to RCA — the event alone is not sufficient, and `event.time` is
  deliberately ignored.
- S3 object key is `investigations-v2/account_id=<id>/agentspace_id=<id>/<executionId>.json`
  — no date in the path, by design (see implementation guide).
- Deployment order is Dashboard Account first, then workload accounts. The arrows show data
  flow, not deployment order.
- The diagram shows **one Region**. An Agent Space monitors its accounts' resources across all
  Regions, so the Region drawn here is the Region the Agent Spaces live in — not the Regions the
  investigated workloads run in. Multi-Region aggregation is not implemented.
- QuickSight shows a **4-sheet analysis** (Overview, Effectiveness, Investigations,
  Cost & Recommendations). Earlier drafts said 5 sheets.
- There are **two** collector Lambdas in each workload account: the investigation collector
  (EventBridge-driven) and the recommendation collector (weekly schedule). Earlier drafts of this
  diagram showed only one.
