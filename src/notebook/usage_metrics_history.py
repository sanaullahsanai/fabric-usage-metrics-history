"""Tenant-wide report usage from the Power BI Admin Activity Events REST API.

No XMLA, source workspace list, or built-in Usage Metrics model is required.
Run in Fabric with a default Lakehouse and a Fabric administrator as owner.
"""

import base64
from collections import deque
from datetime import date, datetime, timedelta, timezone
import hashlib
import json
import time
from urllib.parse import unquote

RETENTION_DAYS = 730
BACKFILL_DAYS = 27
REPLAY_DAYS = 3
EXPOSE_IDENTITY = False
SEMANTIC_MODEL_NAME = "Tenant Usage Metrics"

API_ROOT = "https://api.powerbi.com/v1.0/myorg"
STRING_FIELDS = [
    "EventKey", "Id", "TenantId", "CreationTime", "Activity", "ReportId",
    "ReportName", "WorkspaceId", "WorkspaceName", "UserId", "UserKey",
    "DistributionMethod", "ConsumptionMethod", "CapacityId", "CapacityName",
    "DatasetId", "DatasetName", "AppName", "ReportType", "IsSuccess",
]
VIEW_COLUMNS = [
    "EventKey", "EventDate", "ReportKey", "WorkspaceId", "UserId",
    "DistributionMethod", "ConsumptionMethod",
]


def utc_today():
    return datetime.now(timezone.utc).date()


def retention_cutoff(today, days):
    if days < 0:
        raise ValueError("retentionDays must be nonnegative")
    return today - timedelta(days=days - 1) if days else None


def days_to_fetch(today, completed, backfill_days, replay_days):
    if not 1 <= backfill_days <= 27 or not 1 <= replay_days <= 27:
        raise ValueError("backfillDays and replayDays must be between 1 and 27")
    earliest = today - timedelta(days=27)
    first = min(completed) if completed else today - timedelta(days=backfill_days)
    start = max(earliest, first)
    return [
        start + timedelta(days=i)
        for i in range((today - start).days)
        if start + timedelta(days=i) not in completed
        or start + timedelta(days=i) >= today - timedelta(days=replay_days)
    ]


def normalize_event(event, tenant_id, requested_day, expose_identity):
    if event.get("Activity", event.get("Operation")) != "ViewReport":
        raise ValueError("Activity Events returned an unexpected activity")
    event_id = event.get("Id")
    timestamp = event.get("CreationTime")
    if not event_id or not timestamp:
        raise ValueError("Activity event is missing Id or CreationTime")
    parsed = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    event_day = (parsed.astimezone(timezone.utc).date() if parsed.tzinfo else parsed.date())
    if event_day != requested_day:
        raise ValueError("Activity event is outside its requested UTC day")
    organization = event.get("OrganizationId") or tenant_id
    if organization.lower() != tenant_id.lower():
        raise ValueError("Activity event belongs to a different tenant")
    row = {key: None if event.get(key) is None else str(event[key])
           for key in STRING_FIELDS}
    row.update({
        "EventKey": f"{tenant_id}:{event_id}",
        "TenantId": tenant_id,
        "Activity": "ViewReport",
        "EventDate": event_day,
        "WorkspaceName": event.get("WorkSpaceName") or event.get("WorkspaceName"),
        "ReportId": event.get("ReportId") or event.get("ObjectId"),
        "ReportName": event.get("ReportName") or event.get("ItemName"),
    })
    for field in ("UserId", "UserKey"):
        if row[field] and not expose_identity:
            row[field] = hashlib.sha256(row[field].strip().lower().encode()).hexdigest()
    return row


class ActivityClient:
    """Follow all continuation tokens, including empty intermediate pages."""

    def __init__(self, token_provider, session=None, sleep=time.sleep,
                 clock=time.monotonic):
        if session is None:
            import requests
            session = requests.Session()
        self.session = session
        self.token_provider = token_provider
        self.sleep = sleep
        self.clock = clock
        self.requests = deque()

    def get(self, params):
        from requests.exceptions import ConnectionError, Timeout

        for attempt in range(6):
            now = self.clock()
            while self.requests and now - self.requests[0] >= 3600:
                self.requests.popleft()
            if len(self.requests) >= 180:
                self.sleep(max(1, 3601 - (now - self.requests[0])))
                continue
            self.requests.append(self.clock())
            try:
                response = self.session.get(
                    f"{API_ROOT}/admin/activityevents", params=params,
                    headers={"Authorization": f"Bearer {self.token_provider()}"},
                    timeout=(30, 120),
                )
            except (ConnectionError, Timeout):
                if attempt == 5:
                    raise
                delay = min(120, 2 ** attempt * 5)
                print(f"Activity Events connection failure; retry in {delay}s")
                self.sleep(delay)
                continue
            if response.status_code in (401, 403):
                raise PermissionError(
                    f"Activity Events HTTP {response.status_code}. The notebook owner "
                    "must be a Fabric administrator with delegated Tenant.Read.All "
                    "or Tenant.ReadWrite.All. Workspace access alone is insufficient."
                )
            if response.status_code in (429, 500, 502, 503, 504) and attempt < 5:
                retry = response.headers.get("Retry-After", "")
                delay = int(retry) if retry.isdigit() else min(120, 2 ** attempt * 5)
                print(f"Activity Events HTTP {response.status_code}; retry in {delay}s")
                self.sleep(delay)
                continue
            response.raise_for_status()
            result = response.json()
            if "activityEventEntities" not in result:
                raise ValueError("Activity Events response has no activityEventEntities")
            return result
        raise TimeoutError("Activity Events retry/request budget exhausted")

    def pages(self, day):
        params = {
            "startDateTime": f"'{day.isoformat()}T00:00:00.000Z'",
            "endDateTime": f"'{day.isoformat()}T23:59:59.999Z'",
            "$filter": "Activity eq 'ViewReport'",
        }
        seen = set()
        while True:
            result = self.get(params)
            yield result["activityEventEntities"]
            token = result.get("continuationToken")
            if not token:
                if result.get("continuationUri"):
                    raise ValueError("Continuation URI returned without a token")
                break
            if token in seen:
                raise ValueError("Activity Events repeated a continuation token")
            seen.add(token)
            params = {"continuationToken": "'" + unquote(token).strip("'") + "'"}


def main():
    from delta.tables import DeltaTable
    from pyspark.sql import functions as F, Window
    from pyspark.sql.types import (
        StructType, StructField, StringType, DateType, TimestampType, LongType,
    )
    import notebookutils

    spark.conf.set("spark.sql.session.timeZone", "UTC")
    today = utc_today()
    cutoff = retention_cutoff(today, RETENTION_DAYS)
    if not isinstance(EXPOSE_IDENTITY, bool):
        raise ValueError("exposeIdentity must be a JSON boolean")
    token_provider = lambda: notebookutils.credentials.getToken("pbi")
    token = token_provider()
    claims = json.loads(base64.urlsafe_b64decode(token.split(".")[1] + "==="))
    tenant_id = claims["tid"]
    client = ActivityClient(token_provider)
    raw_schema = StructType(
        [StructField(c, StringType(), True) for c in STRING_FIELDS]
        + [StructField("EventDate", DateType(), False),
           StructField("IngestedUtc", TimestampType(), False)]
    )
    checkpoint_schema = StructType([
        StructField("TenantId", StringType(), False),
        StructField("EventDate", DateType(), False),
        StructField("CompletedUtc", TimestampType(), False),
        StructField("ReturnedRows", LongType(), False),
    ])
    for name, schema in (("audit_report_events", raw_schema),
                         ("audit_ingestion_days", checkpoint_schema)):
        if not spark.catalog.tableExists(name):
            spark.createDataFrame([], schema).write.format("delta").saveAsTable(name)

    completed = {
        r.EventDate for r in spark.table("audit_ingestion_days")
        .filter(F.col("TenantId") == tenant_id).select("EventDate").collect()
    }
    # Detect collection gaps that can no longer be recovered from the 28-day API.
    gaps = []
    if completed:
        first = max(min(completed), cutoff) if cutoff else min(completed)
        earliest = today - timedelta(days=27)
        gaps = [first + timedelta(days=i)
                for i in range(max(0, (earliest - first).days))
                if first + timedelta(days=i) not in completed]

    planned = days_to_fetch(today, completed, BACKFILL_DAYS, REPLAY_DAYS)
    for day in planned:
        returned = 0
        for events in client.pages(day):
            now = datetime.now(timezone.utc).replace(tzinfo=None)
            rows = [dict(normalize_event(e, tenant_id, day, EXPOSE_IDENTITY),
                         IngestedUtc=now) for e in events]
            if rows:
                batch = spark.createDataFrame(rows, raw_schema).dropDuplicates(["EventKey"])
                (DeltaTable.forName(spark, "audit_report_events").alias("t")
                 .merge(batch.alias("s"), "t.EventKey = s.EventKey")
                 .whenMatchedUpdateAll().whenNotMatchedInsertAll().execute())
            returned += len(rows)
        done = spark.createDataFrame(
            [(tenant_id, day, datetime.now(timezone.utc).replace(tzinfo=None), returned)],
            checkpoint_schema,
        )
        (DeltaTable.forName(spark, "audit_ingestion_days").alias("t")
         .merge(done.alias("s"), "t.TenantId = s.TenantId AND t.EventDate = s.EventDate")
         .whenMatchedUpdateAll().whenNotMatchedInsertAll().execute())
        print(f"{day}: all pages committed, {returned} report-open events returned")

    if cutoff:
        for name in ("audit_report_events", "audit_ingestion_days"):
            DeltaTable.forName(spark, name).delete(F.col("EventDate") < F.lit(cutoff))

    events = spark.table("audit_report_events").filter(
        (F.col("Activity") == "ViewReport")
        & (F.lower(F.coalesce("IsSuccess", F.lit("true"))) != "false")
    )
    events = events.withColumn("WorkspaceId", F.coalesce("WorkspaceId", F.lit("Unknown")))
    events = events.withColumn("ReportId", F.coalesce("ReportId", F.lit("Unknown")))
    events = events.withColumn(
        "ReportKey", F.concat_ws(":", "TenantId", "WorkspaceId", "ReportId")
    )
    for col in ("DistributionMethod", "ConsumptionMethod"):
        events = events.withColumn(col, F.coalesce(F.col(col), F.lit("Unknown")))
    latest = Window.partitionBy("ReportKey").orderBy(
        F.desc("CreationTime"), F.desc("EventKey")
    )
    reports = (events.withColumn("_rn", F.row_number().over(latest)).filter("_rn = 1")
               .select("ReportKey", "ReportId", "ReportName", "WorkspaceId", "WorkspaceName")
               .withColumn("ReportName", F.coalesce("ReportName", "ReportId"))
               .withColumn("WorkspaceName", F.coalesce("WorkspaceName", "WorkspaceId")))
    first = events.agg(F.min("EventDate")).first()[0] or today - timedelta(days=26)
    dates = spark.sql(
        f"SELECT explode(sequence(DATE'{first}', DATE'{today}', interval 1 day)) AS Date"
    ).withColumn("Year", F.year("Date")).withColumn(
        "Month", F.date_format("Date", "yyyy-MM")
    )
    for name, df in (
        ("audit_report_views", events.select(*VIEW_COLUMNS)),
        ("audit_reports", reports),
        ("audit_dates", dates),
    ):
        df.write.format("delta").mode("overwrite").option(
            "overwriteSchema", "true"
        ).saveAsTable(name)
        print(f"{name}: {spark.table(name).count()} rows")

    if gaps:
        raise RuntimeError(
            f"{len(gaps)} UTC days could not be recovered (first: {gaps[0]}). "
            "The API only exposes the last 28 days. Curated data was updated, "
            "but coverage is incomplete; inspect audit_ingestion_days."
        )

    if SEMANTIC_MODEL_NAME:
        import sempy.fabric as fabric
        workspace = notebookutils.runtime.context["currentWorkspaceId"]
        lakehouse = notebookutils.runtime.context["defaultLakehouseId"]
        rest = fabric.FabricRestClient()
        headers = {"x-ms-fabric-skill": "spark-cli"}
        lh = rest.get(f"v1/workspaces/{workspace}/lakehouses/{lakehouse}",
                      headers=headers).json()
        endpoint = lh["properties"]["sqlEndpointProperties"]["id"]
        response = rest.post(
            f"v1/workspaces/{workspace}/sqlEndpoints/{endpoint}/refreshMetadata",
            json={}, headers=headers,
        )
        response.raise_for_status()
        if response.status_code == 202:
            location = response.headers["Location"]
            deadline = time.monotonic() + 600
            while time.monotonic() < deadline:
                time.sleep(5)
                poll = rest.get(location, headers=headers)
                poll.raise_for_status()
                status = poll.json()["status"]
                if status == "Succeeded":
                    break
                if status in ("Failed", "Cancelled"):
                    raise RuntimeError(f"SQL metadata sync {status}")
            else:
                raise TimeoutError("SQL metadata sync timed out")
        datasets = []
        url = f"v1/workspaces/{workspace}/semanticModels"
        while url:
            response = rest.get(url, headers=headers)
            response.raise_for_status()
            page = response.json()
            datasets.extend(page["value"])
            url = page.get("continuationUri")
        models = [m for m in datasets if m["displayName"] == SEMANTIC_MODEL_NAME]
        if len(models) != 1:
            raise RuntimeError(f"Expected one semantic model '{SEMANTIC_MODEL_NAME}'")
        model_id = models[0]["id"]
        # Refresh through REST, not XMLA; fail the run if the refresh fails.
        import requests
        refresh_url = f"{API_ROOT}/groups/{workspace}/datasets/{model_id}/refreshes"
        auth = lambda: {"Authorization": f"Bearer {token_provider()}"}
        response = requests.post(refresh_url, headers=auth(),
                                 json={"type": "full"}, timeout=120)
        response.raise_for_status()
        location = response.headers.get("Location")
        if not location:
            raise RuntimeError("Refresh response has no Location for status tracking")
        deadline = time.monotonic() + 1800
        while time.monotonic() < deadline:
            time.sleep(15)
            response = requests.get(location, headers=auth(), timeout=120)
            response.raise_for_status()
            status = response.json().get("status")
            if status == "Completed":
                print("Semantic model refresh completed")
                break
            if status in ("Failed", "Cancelled", "Disabled"):
                raise RuntimeError(f"Semantic model refresh {status}")
        else:
            raise TimeoutError("Semantic model refresh timed out")


if __name__ == "__main__":
    main()
