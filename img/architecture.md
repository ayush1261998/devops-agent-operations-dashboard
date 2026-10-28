# Architecture Diagram

The architecture diagram is maintained **inline in the repository [`README.md`](../README.md#architecture)** as a [Mermaid](https://mermaid.js.org/) flowchart — GitHub renders it automatically, so there is no exported image to keep in sync. This file is the **maintenance spec** for that diagram: when you edit the Mermaid block in the README, keep it consistent with the requirements below.

## What the diagram must show

- **Two kinds of Region.** Workload-side boxes are per workload account × Agent Space Region. The dashboard side is in exactly one analytics Region. Label both so a reader cannot assume everything is in one Region.
- **Replication is cross-account, and cross-Region where the collector and dashboard Regions differ.** One arrow style is fine; its label must say both.
- **Two Lambda functions per collection stack:** the investigation collector (EventBridge-driven) and the inventory collector (every 2 days).
- **The failed-events queue** receives failed invocations from both functions and events EventBridge could not deliver.
- **Glue tables are declared by the dashboard stack.** There is no Glue crawler.
- **The collection stack can be deployed by a StackSet** across an organization, or per account.
- **QuickSight** shows a published dashboard: Overview (including the Coverage table), Effectiveness, Investigations, Cost & Recommendations.
- **No mitigation collector.** Mitigation data is out of scope.
- Arrows show data flow, not deployment order. Deployment order is: dashboard stack, QuickSight setup, collection stacks, backfill.
- The workload-side Region is where the **Agent Spaces** live, not the Regions of the investigated workloads.
