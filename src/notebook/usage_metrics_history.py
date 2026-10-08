# Usage Metrics History - daily snapshot
#
# Power BI's built-in "Usage Metrics Report" semantic model only keeps a
# rolling ~30 days. This notebook reads that model in each source workspace
# over XMLA (semantic-link) and:
#
#   1. APPENDS a full snapshot of its six source tables to Delta tables
#      usage_metrics_<table>, stamped with SnapshotUtc (raw, append-only).
#   2. Rebuilds curated tables um_<table> with the exact columns of the
#      original model, deduplicated across snapshots. The "Usage Metrics
#      History" semantic model imports these through the SQL endpoint.
#   3. Applies retention (RETENTION_DAYS of usage history).
#   4. Triggers a refresh of the semantic model so the report is current.
#
# Pattern after: https://actionablereporting.com/2026/05/12/unlimited-power-bi-usage-history-snapshot-the-built-in-usage-metrics-model-to-lakehouse/
#
# deploy\Deploy.ps1 publishes this file as a notebook and rewrites the
# parameter lines below from config\settings.json. Edit the config and
# re-deploy rather than editing the published notebook.
#
# Prerequisites: Fabric/Premium/PPU capacity with XMLA read, tenant setting
# "Usage metrics for content creators" on, and someone has opened
# "View usage metrics report" on a report in each source workspace once.

import re
import time
import hashlib
from datetime import datetime, timedelta, timezone

import pandas as pd
import sempy.fabric as fabric
from pyspark.sql import functions as F
from pyspark.sql import Window
from pyspark.sql.types import StructType, StructField, StringType, TimestampType, BooleanType, LongType

# Workspace names or ids to snapshot. Empty = every accessible workspace that
# has a usage metrics model.
SOURCE_WORKSPACES = []

# Days of usage history to keep. 0 keeps everything.
RETENTION_DAYS = 730

# False = UserId/UserKey are SHA-256 hashed before they are stored.
EXPOSE_IDENTITY = True

# Semantic model refreshed at the end of the run ("" to skip).
SEMANTIC_MODEL_NAME = "Usage Metrics History"

DATASET_NAME = "Usage Metrics Report"
RAW_PREFIX = "usage_metrics_"
IDENTITY_COLUMNS = {"UserId", "UserKey"}

SNAPSHOT_UTC = datetime.now(timezone.utc).replace(microsecond=0, tzinfo=None)
TODAY = SNAPSHOT_UTC.date()
print(f"Snapshot timestamp (UTC): {SNAPSHOT_UTC.isoformat()}  retention={RETENTION_DAYS or 'forever'} days")


# ----------------------------------------------------------------------------
# Curated table definitions (columns and types of the original model)
# ----------------------------------------------------------------------------

S, T, B, L = StringType(), TimestampType(), BooleanType(), LongType()

# source table -> (curated table, event time column or None, [(column, type)])
TABLES = {
    "Report views": ("um_report_views", "CreationTime", [
        ("ReportId", S), ("ReportType", S), ("ReportName", S), ("AppName", S), ("UserKey", S),
        ("UserId", S), ("UserAgent", S), ("DatasetName", S), ("DistributionMethod", S),
        ("CapacityId", S), ("CapacityName", S), ("CreationTime", T), ("OriginalConsumptionMethod", S)]),
    "Report page views": ("um_report_page_views", "Timestamp", [
        ("Timestamp", T), ("AppName", S), ("TenantId", S), ("UserId", S), ("ReportId", S),
        ("OriginalReportId", S), ("WorkspaceId", S), ("OriginalWorkspaceId", S), ("AppGuid", S),
        ("SectionId", S), ("Client", S), ("SessionSource", S), ("DeviceOSVersion", S),
        ("DeviceBrowserVersion", S), ("UserKey", S)]),
    "Report load times": ("um_report_load_times", "Timestamp", [
        ("Timestamp", T), ("PbiCluster", S), ("AppName", S), ("TenantId", S), ("UserId", S),
        ("ReportId", S), ("GroupId", S), ("Client", S), ("StartTime", T), ("EndTime", T),
        ("DeviceOSVersion", S), ("LocationCity", S), ("Country", S), ("OriginalReportId", S),
        ("OriginalGroupId", S), ("DeviceBrowserVersion", S), ("AppGuid", S), ("SessionSource", S)]),
    "Reports": ("um_reports", None, [
        ("OrganizationId", S), ("ReportGuid", S), ("ReportName", S), ("WorkspaceId", S),
        ("IsUsageMetricsReport", B)]),
    "Report pages": ("um_report_pages", None, [
        ("ReportId", S), ("SectionId", S), ("SectionName", S), ("WorkspaceId", S)]),
    "Report rank": ("um_report_rank", None, [
        ("ReportId", S), ("WorkspaceId", S), ("ReportViewCount", L), ("ReportRank", L),
        ("TotalReportCount", L), ("TenantId", S)]),
}

# Key that must stay unique in the model (relationship "one" side).
DIM_KEYS = {"Reports": ["ReportGuid"], "Report pages": ["SectionId"], "Report rank": ["ReportId"]}


def raw_name(table):
    return RAW_PREFIX + re.sub(r"[^0-9a-z]+", "_", table.lower()).strip("_")


def table_exists(name):
    return spark.catalog.tableExists(name)


# ----------------------------------------------------------------------------
# Discover source models
# ----------------------------------------------------------------------------

def _pick_col(df, candidates):
    for c in candidates:
        if c in df.columns:
            return c
    return None


def _model_responds(ws_id):
    # The usage metrics model is hidden and may not be listed; probe it by name.
    try:
        fabric.evaluate_dax(dataset=DATASET_NAME, workspace=ws_id, dax_string='EVALUATE ROW("ok", 1)')
        return True
    except Exception:
        return False


def find_usage_models():
    all_ws = fabric.list_workspaces()
    id_col = _pick_col(all_ws, ["Id", "id", "Workspace Id"])
    nm_col = _pick_col(all_ws, ["Name", "name", "Workspace Name"])
    if all_ws.empty or id_col is None or nm_col is None:
        print(f"No workspaces visible (columns: {list(all_ws.columns)})")
        return []
    if SOURCE_WORKSPACES:
        wanted = {str(w).lower() for w in SOURCE_WORKSPACES}
        all_ws = all_ws[all_ws[id_col].astype(str).str.lower().isin(wanted)
                        | all_ws[nm_col].astype(str).str.lower().isin(wanted)]
        missing = wanted - set(all_ws[id_col].astype(str).str.lower()) - set(all_ws[nm_col].astype(str).str.lower())
        for m in missing:
            print(f"  WARNING: source workspace '{m}' not found or not accessible")

    found = []
    for _, ws in all_ws.iterrows():
        ws_id, ws_name = str(ws[id_col]), str(ws[nm_col])
        try:
            ds = fabric.list_datasets(workspace=ws_id)
        except Exception as ex:
            print(f"  skip workspace '{ws_name}': {str(ex)[:120]}")
            continue
        name_col = _pick_col(ds, ["Dataset Name", "Name", "name"])
        listed = set(ds[name_col].astype(str)) if (not ds.empty and name_col) else set()
        if DATASET_NAME in listed or (SOURCE_WORKSPACES and _model_responds(ws_id)):
            found.append((ws_id, ws_name))
    return found


models = find_usage_models()
print(f"Found {len(models)} usage metrics model(s):")
for ws_id, ws_name in models:
    print(f"  {ws_name} ({ws_id})")
if not models:
    print("Nothing to snapshot. Open 'View usage metrics report' on a report in each "
          "source workspace once to create the model, then re-run.")


# ----------------------------------------------------------------------------
# Snapshot (append to raw tables)
# ----------------------------------------------------------------------------

def clean_column(name):
    # 'Table'[Column] -> Column, then make it Delta-safe.
    if "[" in name:
        name = name.split("[")[-1].rstrip("]")
    name = re.sub(r"[^0-9A-Za-z_]+", "_", name.strip()).strip("_")
    return name or "col"


def _is_null(v):
    try:
        return v is None or bool(pd.isna(v))
    except (TypeError, ValueError):
        return False


def hash_value(v):
    if _is_null(v):
        return None
    return hashlib.sha256(str(v).strip().lower().encode("utf-8")).hexdigest()


def to_text(v):
    if _is_null(v):
        return None
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    if isinstance(v, pd.Timestamp):
        return v.strftime("%Y-%m-%d %H:%M:%S.%f")
    return str(v)


def evaluate_with_retry(ws_id, dax, attempts=3):
    # The first XMLA call to a cold model can time out; retry transient errors.
    for i in range(1, attempts + 1):
        try:
            return fabric.evaluate_dax(dataset=DATASET_NAME, workspace=ws_id, dax_string=dax)
        except Exception as ex:
            if i == attempts or not re.search(r"timed out|connection|was lost|temporar|throttl|429|503", str(ex), re.I):
                raise
            print(f"    transient error (attempt {i}/{attempts}), retrying: {str(ex)[:80]}")
            time.sleep(30 * i)


def snapshot_table(ws_id, ws_name, table):
    escaped = table.replace("'", "''")
    pdf = evaluate_with_retry(ws_id, f"EVALUATE '{escaped}'")
    if pdf is None or len(pdf) == 0:
        return 0

    cols, seen = [], {}
    for c in pdf.columns:
        n = clean_column(c)
        seen[n] = seen.get(n, 0) + 1
        cols.append(n if seen[n] == 1 else f"{n}_{seen[n]}")
    pdf.columns = cols

    if not EXPOSE_IDENTITY:
        for c in pdf.columns:
            if c in IDENTITY_COLUMNS:
                pdf[c] = pdf[c].map(hash_value)

    # Raw tables are all-string so that type drift between runs (e.g. an int
    # column arriving as float because of nulls) never breaks the append. The
    # curated step casts to the model's types.
    for c in pdf.columns:
        pdf[c] = pdf[c].map(to_text)
    schema = StructType([StructField(c, StringType(), True) for c in pdf.columns])

    sdf = (spark.createDataFrame(pdf.astype(object).where(pd.notnull(pdf), None), schema)
           .withColumn("SnapshotUtc", F.lit(SNAPSHOT_UTC).cast("timestamp"))
           .withColumn("SourceWorkspaceId", F.lit(ws_id))
           .withColumn("SourceWorkspaceName", F.lit(ws_name)))

    (sdf.write.format("delta").mode("append")
        .option("mergeSchema", "true")
        .saveAsTable(raw_name(table)))
    return len(pdf)


results = []
for ws_id, ws_name in models:
    print(f"\n{ws_name}")
    for table in TABLES:
        try:
            rows = snapshot_table(ws_id, ws_name, table)
            results.append((ws_name, table, rows, "ok"))
            print(f"  {table:<20} {rows:>8} rows")
        except Exception as ex:
            msg = (str(ex).splitlines() or [type(ex).__name__])[0][:150]
            results.append((ws_name, table, 0, "error"))
            print(f"  {table:<20} ERROR {msg}")

errors = [r for r in results if r[3] == "error"]


# ----------------------------------------------------------------------------
# Retention (raw tables)
# ----------------------------------------------------------------------------

cutoff = TODAY - timedelta(days=RETENTION_DAYS) if RETENTION_DAYS else None

if cutoff:
    for table, (_, ts_col, _) in TABLES.items():
        raw = raw_name(table)
        if not table_exists(raw):
            continue
        if ts_col:
            spark.sql(f"DELETE FROM {raw} WHERE to_date({ts_col}) < DATE'{cutoff}'")
        else:
            # Keep at least the latest snapshot of each dimension.
            latest = spark.table(raw).agg(F.max("SnapshotUtc")).first()[0]
            keep_from = min(datetime.combine(cutoff, datetime.min.time()), latest) if latest else None
            if keep_from:
                spark.sql(f"DELETE FROM {raw} WHERE SnapshotUtc < TIMESTAMP'{keep_from:%Y-%m-%d %H:%M:%S}'")
    print(f"Retention: removed usage older than {cutoff}.")
else:
    print("Retention: disabled, keeping all history.")


# ----------------------------------------------------------------------------
# Build curated tables (um_*)
# ----------------------------------------------------------------------------

def conform(df, columns):
    # Select the model's columns with the model's types; missing ones are null.
    out = []
    for name, dtype in columns:
        if name not in df.columns:
            out.append(F.lit(None).cast(dtype).alias(name))
        elif isinstance(dtype, BooleanType):
            out.append(F.lower(F.col(name).cast("string")).isin("true", "1").alias(name))
        elif isinstance(dtype, TimestampType):
            out.append(F.to_timestamp(F.col(name)).alias(name))
        else:
            out.append(F.col(name).cast(dtype).alias(name))
    return out


def best_snapshot_rows(df, ts_col):
    # Each snapshot repeats the trailing ~30 days. For every source workspace and
    # event date, keep the snapshot that holds the most rows for that date (the
    # most complete one); ties go to the newest snapshot.
    df = df.withColumn("_d", F.to_date(F.col(ts_col)))
    counts = df.groupBy("SourceWorkspaceId", "_d", "SnapshotUtc").count()
    w = Window.partitionBy("SourceWorkspaceId", "_d").orderBy(F.desc("count"), F.desc("SnapshotUtc"))
    best = (counts.withColumn("_rn", F.row_number().over(w))
            .filter("_rn = 1").select("SourceWorkspaceId", "_d", "SnapshotUtc"))
    return df.join(best, ["SourceWorkspaceId", "_d", "SnapshotUtc"]), best


def latest_per_key(df, keys):
    w = Window.partitionBy(*keys).orderBy(F.desc("SnapshotUtc"))
    return df.withColumn("_rn", F.row_number().over(w)).filter("_rn = 1").drop("_rn")


def unify_user_ids(df, ts_col):
    # The model's Users table looks up one UserId per UserKey, so a user whose
    # UPN changed during the retained history must resolve to a single value.
    if "UserKey" not in df.columns or "UserId" not in df.columns:
        return df
    w = Window.partitionBy("UserKey").orderBy(F.desc(ts_col))
    latest = (df.filter(F.col("UserKey").isNotNull())
              .withColumn("_rn", F.row_number().over(w)).filter("_rn = 1")
              .select("UserKey", F.col("UserId").alias("_uid")))
    return (df.join(latest, "UserKey", "left")
            .withColumn("UserId", F.coalesce("_uid", "UserId")).drop("_uid"))


curated_counts = {}
for table, (target, ts_col, columns) in TABLES.items():
    raw = raw_name(table)
    if table_exists(raw):
        df = spark.table(raw)
        if ts_col:
            df, _ = best_snapshot_rows(df, ts_col)
            if cutoff:
                df = df.filter(F.col("_d") >= F.lit(cutoff))
        else:
            df = latest_per_key(df, DIM_KEYS[table])
        out = df.select(*conform(df, columns))
        if ts_col:
            out = unify_user_ids(out, ts_col)
            out = out.select(*[c for c, _ in columns])
        out = out.filter(" AND ".join(f"{k} IS NOT NULL" for k in DIM_KEYS.get(table, [])) or "1=1")
    else:
        out = spark.createDataFrame([], StructType([StructField(c, t, True) for c, t in columns]))

    (out.write.format("delta").mode("overwrite")
        .option("overwriteSchema", "true")
        .saveAsTable(target))
    curated_counts[target] = spark.table(target).count()
    print(f"  {target:<24} {curated_counts[target]:>9} rows")


# ----------------------------------------------------------------------------
# Compact raw facts
# ----------------------------------------------------------------------------

# Dates older than the source window (~30 days) can no longer change, so only
# the winning snapshot of those dates is kept. Raw storage stays ~1x instead
# of growing ~30x.
SETTLED = TODAY - timedelta(days=35)
for table, (_, ts_col, _) in TABLES.items():
    raw = raw_name(table)
    if not ts_col or not table_exists(raw):
        continue
    df = spark.table(raw).withColumn("_d", F.to_date(F.col(ts_col)))
    counts = df.groupBy("SourceWorkspaceId", "_d", "SnapshotUtc").count()
    w = Window.partitionBy("SourceWorkspaceId", "_d").orderBy(F.desc("count"), F.desc("SnapshotUtc"))
    losers = (counts.withColumn("_rn", F.row_number().over(w))
              .filter(f"_rn > 1 AND _d < DATE'{SETTLED}'")
              .select("SourceWorkspaceId", "_d", "SnapshotUtc"))
    losers.createOrReplaceTempView("_losers")
    spark.sql(f"""
        MERGE INTO {raw} t
        USING _losers s
        ON t.SourceWorkspaceId = s.SourceWorkspaceId
           AND to_date(t.{ts_col}) = s._d
           AND t.SnapshotUtc = s.SnapshotUtc
        WHEN MATCHED THEN DELETE""")


# ----------------------------------------------------------------------------
# Health check and model refresh
# ----------------------------------------------------------------------------

for table, (target, ts_col, _) in TABLES.items():
    if ts_col:
        s = spark.sql(f"""SELECT COUNT(*) AS n, MIN(to_date({ts_col})) AS first_day,
                                 MAX(to_date({ts_col})) AS last_day,
                                 COUNT(DISTINCT to_date({ts_col})) AS days
                          FROM {target}""").first()
        print(f"{target:<24} rows={s.n:<9} days={s.days:<5} first={s.first_day} last={s.last_day}")

def sync_sql_endpoint():
    # The model reads through the SQL endpoint, whose metadata can lag behind new Delta tables.
    import time
    client = fabric.FabricRestClient()
    ws = fabric.get_workspace_id()
    lh_id = notebookutils.runtime.context.get("defaultLakehouseId")
    lh = client.get(f"v1/workspaces/{ws}/lakehouses/{lh_id}").json()
    ep_id = lh["properties"]["sqlEndpointProperties"]["id"]
    r = client.post(f"v1/workspaces/{ws}/sqlEndpoints/{ep_id}/refreshMetadata", json={})
    if r.status_code == 202 and r.headers.get("Location"):
        for _ in range(60):
            time.sleep(int(r.headers.get("Retry-After", 5)))
            st = client.get(r.headers["Location"]).json().get("status")
            if st in ("Succeeded", "Failed", "Cancelled"):
                break
    print("SQL endpoint metadata synced.")

if SEMANTIC_MODEL_NAME and not errors:
    try:
        sync_sql_endpoint()
    except Exception as ex:
        print(f"SQL endpoint sync skipped: {str(ex)[:200]}")
    try:
        own_ws = fabric.get_workspace_id()
        fabric.refresh_dataset(dataset=SEMANTIC_MODEL_NAME, workspace=own_ws, refresh_type="full")
        print(f"Refresh of '{SEMANTIC_MODEL_NAME}' requested.")
    except Exception as ex:
        print(f"Semantic model refresh not requested: {str(ex)[:200]}")

if errors:
    raise RuntimeError(f"{len(errors)} table(s) failed to snapshot: "
                       + ", ".join(f"{w}/{t}" for w, t, _, _ in errors))
