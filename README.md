# Fabric Usage Metrics History

Keeps Power BI **report usage metrics for longer than 30 days**.

The built-in *Usage Metrics Report* only holds a rolling ~30 days. This solution:

1. **Snapshots** the built-in usage-metrics semantic model of one or more workspaces into a Lakehouse every day (append-only).
2. **Curates** the snapshots into deduplicated `um_*` tables, with configurable **retention**.
3. Deploys an **exact clone** of Microsoft's *Usage Metrics Report* semantic model and report. Only the six data-source partitions are re-pointed to the Lakehouse, so every page, visual, measure and slicer works the same way, just with full history.

See [docs/architecture.md](docs/architecture.md) for the diagrams, the daily flow and the data model.

## What gets deployed

| Item | Default name | Purpose |
|---|---|---|
| Workspace | `WS-UsageMetrics` | Hosts the solution; its workspace identity is used for unattended refresh |
| Lakehouse | `LH_UsageMetrics` | `usage_metrics_*` raw snapshots, `um_*` curated tables |
| Notebook | `NB_UsageMetricsHistory` | Daily snapshot, retention, curation, SQL endpoint sync, model refresh |
| Schedule | daily at `scheduleTime` | Runs the notebook |
| Connection | `<workspace>-<lakehouse>-SQL` | SQL endpoint connection with **Workspace Identity** credentials |
| Semantic model | `Usage Metrics History` | Clone of the built-in model (Import mode) |
| Report | `Usage Metrics History` | Clone of the built-in *Usage Metrics Report* |

## Prerequisites

- A Fabric capacity (F SKU or P SKU) in the **Active** state, and permission to create workspaces on it.
- Tenant settings: *Usage metrics for content creators* enabled, *XMLA endpoints* allowed (read), *Service principals can use Fabric APIs* (for the workspace identity).
- In **each source workspace**, open *View usage metrics report* once on any report. This creates that workspace's `Usage Metrics Report` model.
- The deploying user is an Admin/Member of the source workspaces. The notebook runs as the schedule owner.
- Azure CLI signed in (`az login`) and Windows PowerShell 5.1+ or PowerShell 7.

## Configure

Copy `config/settings.example.json` to `config/settings.json` (gitignored) and edit it:

| Setting | Meaning |
|---|---|
| `workspaceName` | Workspace to create or reuse |
| `capacityName` / `capacityId` | Capacity to assign the workspace to (name or id) |
| `lakehouseName`, `notebookName`, `semanticModelName`, `reportName` | Item names |
| `connectionName` | Optional. Name of the SQL connection; defaults to `<workspace>-<lakehouse>-SQL` |
| `sourceWorkspaces` | Workspace names or ids whose usage metrics are captured |
| `templateWorkspace` | Optional. Workspace whose `Usage Metrics Report` is cloned (defaults to the first source) |
| **`retentionDays`** | Days of history to keep (e.g. `730` = 2 years). Older rows are deleted on each run |
| **`scheduleTime`** | Daily run time, `HH:mm` (24-hour) |
| **`scheduleTimeZone`** | Windows time-zone id, e.g. `UTC`, `AUS Eastern Standard Time`, `Pacific Standard Time` |
| `exposeIdentity` | `false` hashes user names/emails before they reach the Lakehouse |

## Deploy

```powershell
az login
Set-ExecutionPolicy -Scope Process Bypass -Force
.\deploy\Deploy.ps1
```

The script is idempotent. It creates or updates every item, runs the notebook once, binds the model to the connection, refreshes it and prints the report URL.

### Change retention or schedule later

Edit `retentionDays`, `scheduleTime` or `scheduleTimeZone` in `config/settings.json` and run:

```powershell
.\deploy\Deploy.ps1 -SkipNotebookRun
```

Retention takes effect on the next scheduled run.

## How the history works

- Each run appends the full ~30-day window from each source to `usage_metrics_*`, tagged with `SnapshotUtc` and `SourceWorkspaceId`.
- `um_*` keeps, per source and day, the snapshot with the most rows, so overlapping windows never double count. Dimension tables keep the latest version of each key.
- Superseded snapshots older than 35 days are compacted away, and anything older than `retentionDays` is deleted.
- The report's `Dates` table extends automatically from the first captured day, so the date slicer covers the whole history.
- The only text change to Microsoft's report is the FAQ sentence that says "last 30 days".

## Notes

- Microsoft can change the built-in usage-metrics model. Re-running `Deploy.ps1` re-clones the current template.
- The repository is private because the owning account is an Enterprise Managed User; there is no technical dependency on that.

## License

MIT
