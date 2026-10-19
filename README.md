# Fabric Usage Metrics History

Tenant-wide Power BI report usage from the **Admin Activity Events REST API**,
retained in a Fabric Lakehouse for **730 days** by default.

No XMLA extraction, source-workspace enumeration, or built-in Usage Metrics model
is required. The collector requests `ViewReport` events across the tenant.

## Report experience

- **Report usage:** report opens, unique viewers, active reports, view trend,
  daily views/viewers, users, distribution and consumption methods.
- **Report list:** workspace/report breakdown, views, viewers and rank computed
  for the selected dates. Only reports with captured activity are included.
- **Collection coverage:** completely collected UTC days, including zero-event
  days, and the last collected date.
- Date, workspace and report slicers; retained history automatically extends
  the date range.

This is **similar to**, not an exact copy of, modern Report Usage Metrics.
Activity Events does **not** provide report-page navigation or client report
opening times. Those visuals are deliberately omitted rather than fabricated.
Audit counts can differ from built-in usage metrics because of processing
latency, filters and service-generated opens (including subscription activity).
Reports with no recorded opens are not a complete inventory of unused reports.

## Requirements

- An active Fabric capacity, workspace creation/access rights, and a Lakehouse.
- **Fabric administrator** access for the notebook owner/schedule owner, with
  delegated `Tenant.Read.All` or `Tenant.ReadWrite.All`. Being a workspace Admin
  alone does not grant access to the tenant activity log.
- Azure CLI (`az login`), PowerShell 5.1+ and Python 3 on the deployment machine.
- The Fabric notebook runtime's Power BI token must be allowed to call the
  Admin Activity Events API. Deployment preflights the Azure CLI identity;
  the first notebook run separately verifies the runtime identity.
- The SQL connection uses a workspace identity for model refresh. That identity
  is **not** the identity used to read the tenant audit log.

The default authentication is the notebook owner's delegated token, retrieved
by `notebookutils.credentials.getToken("pbi")`; no credentials are stored.
Service-principal collection would need separately configured admin API access
and an appropriate notebook execution identity; setting up the workspace
identity does not grant it tenant administration.

### Collection user and access setup

Set these alongside the other parameters in `config/settings.json`:

```json
{
  "tenantId": "<Entra tenant GUID>",
  "collectorUserPrincipalName": "collector@contoso.com",
  "collectorUserObjectId": "<user object GUID in that tenant>"
}
```

These fields **select and validate an already-authorized user**. They do not
assign roles, grant consent, impersonate that user, or store a password/token.
Object ID is the stable identifier; a changed UPN requires updating the
configured UPN. Leave fields empty to use the current signed-in identity.
Deployment always pins the notebook to the validated tenant and user object
ID, including when the configuration fields are empty.

1. Have your organization's authorized Entra administrator assign the
   **Fabric Administrator** role to the collection user. If governed through
   Privileged Identity Management (PIM), activate it before deployment and
   collection. A short-lived activation alone is not enough for unattended
   daily collection: the owner must be authorized when each job runs.
2. For a custom delegated client application, request Power BI Service
   **`Tenant.Read.All`** (or the broader `Tenant.ReadWrite.All` only if needed)
   and have an authorized administrator grant tenant consent where required.
   Azure CLI and Fabric notebook tokens are issued to their own client
   applications; consent to a separate custom app does not authorize those
   clients. Do not paste access tokens or secrets into this configuration.
3. Sign in as the configured user:
   `az login --tenant <tenantId>`. This setting does not switch Azure CLI
   accounts automatically.
4. Run the non-mutating check:

   ```powershell
   .\deploy\Deploy.ps1 -PreflightOnly
   ```

   It compares token identity claims with the settings and calls Activity
   Events to verify **effective API access**, without creating workspace
   items or changing roles/consent. An empty result page still proves access;
   the collection job follows pagination to obtain all data. Scope claims
   vary by first-party client, so scope text alone is not used to infer
   authorization.
5. Deploy as that user so the daily schedule is created under the authorized
   account. Every notebook token acquisition checks the pinned tenant/user.
   The first notebook run also verifies API access using the runtime token.
   Workspace Contributor+ access is needed for collection/deployment work;
   tenant admin access does not automatically grant workspace membership.

Changing these settings requires signing in as the new user and redeploying;
it does not transfer ownership by itself. A 401/403 fails explicitly with
setup guidance. Do not grant Global Administrator solely to run this collector.

[Activity Events permissions](https://learn.microsoft.com/rest/api/power-bi/admin/get-activity-events)
and [Assign Microsoft Entra roles](https://learn.microsoft.com/entra/identity/role-based-access-control/manage-roles-portal).

## Configuration

Copy `config/settings.example.json` to gitignored `config/settings.json`.

| Parameter | Default / options |
|---|---|
| `workspaceName` | `WS-UsageMetrics`; choose the target Fabric workspace |
| `capacityName` / `capacityId` | Provide one; ID takes precedence |
| `lakehouseName` | `LH_UsageMetrics` |
| `notebookName` | `NB_UsageMetricsHistory` |
| `semanticModelName` | `Tenant Usage Metrics` |
| `reportName` | `Usage Metrics History` |
| `connectionName` | Empty generates `<workspace>-<lakehouse>-SQL` |
| `tenantId` | Expected Entra tenant GUID; empty uses the current login |
| `collectorUserPrincipalName` | Expected authorized user's UPN; empty uses the current login |
| `collectorUserObjectId` | Expected user's Entra object GUID; empty uses the current login |
| `retentionDays` | `730`; `0` keeps indefinitely. Counts calendar dates including today |
| `backfillDays` | `27`; initial completed UTC days to retrieve, range `1..27` |
| `replayDays` | `3`; recent days to reread for late arrivals, range `1..27` |
| `scheduleTime` | `05:00`, 24-hour `HH:mm` |
| `scheduleTimeZone` | `UTC` or Windows zone such as `AUS Eastern Standard Time` |
| `exposeIdentity` | `false` hashes user IDs/keys before storage; `true` retains them |

`sourceWorkspaces` and `templateWorkspace` are obsolete. The new collector is
tenant-wide regardless of the deploying user's visible workspace list.

## Deploy or update

```powershell
az login
Set-ExecutionPolicy -Scope Process Bypass -Force
.\deploy\Deploy.ps1
```

The script creates/reuses the workspace, identity, Lakehouse and SQL connection;
publishes and runs the collector; builds and refreshes the first-party Import
semantic model; and publishes the report. It prints the report URL.

The **Report usage** and **Report list** pages include **Workspace** and
**Report** dropdown filters alongside the UTC date slicer. Workspace and report
selections filter the page's usage visuals. Collection coverage remains
unfiltered so it shows the collector's overall ingestion health.

To change settings after the audit tables have been initialized:

```powershell
.\deploy\Deploy.ps1 -SkipNotebookRun
```

The initial load can take longer for a busy tenant: every continuation page is
read, even when an intermediate page has no events. A conservative local budget
of 180 requests/hour leaves room under the API's 200 requests/hour limit.
External callers share service limits; 429 responses honor `Retry-After`.
Raise `-TimeoutMinutes` for large initial backfills.

### Migrating the earlier XMLA solution

Run the deployment against the existing workspace, notebook and report names.
Set `semanticModelName` to **`Tenant Usage Metrics`** (or another new name):
Fabric cannot change the legacy model's calculated partitions to M partitions
in place. The new model replaces the report's connection; the old model remains.
The deployment creates separate `audit_*` tables.
Old `usage_metrics_*` and `um_*` tables remain untouched and are **not** unioned
into audit activity (that would risk double-counting). The new report starts
from the Activity Events backfill; old snapshots remain available separately.
Changes to the old report/model definitions are replaced by this managed
deployment; preserve any customizations before upgrading.

## Retention and correctness

The API only exposes the **last 28 days**, queried one UTC day at a time.
We conservatively collect up to 27 completed days, excluding the current day.
You cannot backfill 730 days immediately unless another archive exists.

Each page is MERGEd by tenant + event ID into `audit_report_events`. A day is
checkpointed in `audit_ingestion_days` only after **all** its pages succeed.
Retries and daily replay do not duplicate report opens. Missing days inside the
API window are retried; known gaps beyond it fail explicitly.

`audit_report_views`, `audit_reports` and `audit_dates` are rebuilt from retained
events, not just the latest extraction. Exactly 730 calendar dates are eligible
at the default retention; the current date usually has no events until the next
run. Physical deletion from Delta history/backups is separate from logical
retention and requires your organization's approved VACUUM/backup policy.

The notebook synchronizes SQL metadata and waits for the model refresh; refresh
errors fail the run. Keep the capacity running at the scheduled time, monitor
job failures, and retain at least three days of replay for late-arriving events.

Hashes are **pseudonyms**, not guaranteed anonymization. Changing
`exposeIdentity` after collection does not rewrite older rows outside the replay
window; perform an approved historical privacy migration if needed. Restrict
the monitoring workspace/report: tenant-wide usage is sensitive.

[Architecture and daily flow](docs/architecture.md)

## Local checks

```powershell
python -m unittest discover -s tests -v
.\tests\Test-CollectorAccess.ps1
```

## References

- [Admin Activity Events API](https://learn.microsoft.com/rest/api/power-bi/admin/get-activity-events)
- [Modern Usage Metrics and limitations](https://learn.microsoft.com/power-bi/collaborate-share/service-modern-usage-metrics)

## License

MIT
