"""Build the first-party TMDL model and PBIR report, without a template model."""

import argparse
import base64
import json

SCHEMA_ROOT = "https://developer.microsoft.com/json-schemas/fabric/item/report/"

TABLES = {
    "Report views": ("audit_report_views", [
        ("Event key", "EventKey", "string", True),
        ("Date", "EventDate", "dateTime", True),
        ("Report key", "ReportKey", "string", True),
        ("Workspace identifier", "WorkspaceId", "string", True),
        ("User", "UserId", "string", False),
        ("Distribution method", "DistributionMethod", "string", False),
        ("Consumption method", "ConsumptionMethod", "string", False),
    ]),
    "Reports": ("audit_reports", [
        ("Report key", "ReportKey", "string", True),
        ("Report identifier", "ReportId", "string", False),
        ("Report", "ReportName", "string", False),
        ("Workspace identifier", "WorkspaceId", "string", True),
        ("Workspace", "WorkspaceName", "string", False),
    ]),
    "Dates": ("audit_dates", [
        ("Date", "Date", "dateTime", False),
        ("Year", "Year", "int64", False),
        ("Month", "Month", "string", False),
    ]),
    "Collection": ("audit_ingestion_days", [
        ("Tenant", "TenantId", "string", True),
        ("Collected date", "EventDate", "dateTime", False),
        ("Completed", "CompletedUtc", "dateTime", False),
        ("Returned rows", "ReturnedRows", "int64", True),
    ]),
}

MEASURES = {
    "Report views": [
        ("Report views", "COALESCE(COUNTROWS('Report views'), 0)", "#,##0",
         "Successful ViewReport audit events, deduplicated by tenant and event ID."),
        ("Unique viewers", "COALESCE(DISTINCTCOUNTNOBLANK('Report views'[User]), 0)",
         "#,##0", "Distinct nonblank audit user identifiers in the selected period."),
        ("Active reports", "COALESCE(DISTINCTCOUNT('Report views'[Report key]), 0)",
         "#,##0", "Reports with successful opens in the current filters."),
        ("Active workspaces",
         "COALESCE(DISTINCTCOUNT('Report views'[Workspace identifier]), 0)",
         "#,##0", "Workspaces represented by report-open activity."),
        ("Report rank",
         "IF([Report views] > 0, RANKX(ALLSELECTED('Reports'), [Report views], , DESC, DENSE))",
         "#,##0", "Rank among selected reports, evaluated over the current date filters."),
        ("View trend", """
VAR _dates = ALLSELECTED('Dates'[Date])
VAR _half = INT(COUNTROWS(_dates) / 2)
VAR _early = TOPN(_half, _dates, 'Dates'[Date], ASC)
VAR _late = TOPN(_half, _dates, 'Dates'[Date], DESC)
VAR _before = CALCULATE([Report views], REMOVEFILTERS('Dates'), TREATAS(_early, 'Dates'[Date]))
VAR _after = CALCULATE([Report views], REMOVEFILTERS('Dates'), TREATAS(_late, 'Dates'[Date]))
RETURN IF(_half > 0, DIVIDE(_after - _before, _before))
""".strip(), "0.0%",
         "Change between equal-length first and last halves of the selected dates; "
         "the middle date is excluded when the period has an odd number of days."),
    ],
    "Collection": [
        ("Collected days", "COUNTROWS('Collection')", "#,##0",
         "Successfully paginated UTC days, including days with zero report opens."),
        ("Last collected date", "MAX('Collection'[Collected date])", "yyyy-MM-dd",
         "Most recent completely collected UTC day; independent of report filters."),
    ],
}


def identifier(value):
    return "'" + value.replace("'", "''") + "'"


def model_parts(server, database):
    parts = {
        "definition.pbism": json.dumps({"version": "4.2", "settings": {"qnaEnabled": False}}),
        "definition/database.tmdl": "database\n\tcompatibilityLevel: 1702\n",
        "definition/model.tmdl": (
            "model Model\n\tculture: en-US\n\tdefaultPowerBIDataSourceVersion: powerBI_V3\n"
            "\tsourceQueryCulture: en-US\n\tdiscourageImplicitMeasures\n\n"
            + "\n".join(f"ref table {identifier(t)}" for t in TABLES) + "\n"
        ),
        "definition/expressions.tmdl": "\n\n".join(
            f'expression {name} = {json.dumps(value)} meta '
            '[IsParameterQuery=true, Type="Text", IsParameterQueryRequired=true]'
            for name, value in (("SqlEndpoint", server), ("LakehouseName", database))
        ) + "\n",
        "definition/relationships.tmdl": (
            "relationship ReportDates\n\tfromColumn: 'Report views'.Date\n"
            "\ttoColumn: Dates.Date\n\tcrossFilteringBehavior: oneDirection\n\n"
            "relationship ReportDimension\n\tfromColumn: 'Report views'.'Report key'\n"
            "\ttoColumn: Reports.'Report key'\n\tcrossFilteringBehavior: oneDirection\n"
        ),
    }
    for table, (source, columns) in TABLES.items():
        text = (f"/// {'Collection coverage utility table' if table == 'Collection' else 'Tenant-wide report usage history'}.\n"
                f"table {identifier(table)}\n")
        if table == "Dates":
            text += "\tdataCategory: Time\n"
        for name, dax, fmt, description in MEASURES.get(table, []):
            expression = dax if "\n" not in dax else (
                "```\n" + "\n".join("\t\t" + line for line in dax.splitlines()) + "\n\t\t```"
            )
            text += (f"\n\t/// {description}\n\tmeasure {identifier(name)} = {expression}\n"
                     f"\t\tformatString: {fmt}\n")
        for name, column, dtype, hidden in columns:
            text += (f"\n\t/// {name} from the retained audit activity.\n"
                     f"\tcolumn {identifier(name)}\n\t\tdataType: {dtype}\n"
                     f"\t\tsummarizeBy: none\n\t\tsourceColumn: {column}\n")
            if hidden:
                text += "\t\tisHidden\n"
            if dtype == "dateTime":
                text += "\t\tformatString: yyyy-MM-dd\n"
        text += (
            f"\n\tpartition {identifier(table)} = m\n\t\tmode: import\n\t\tsource =\n"
            "\t\t\tlet\n\t\t\t\tSource = Sql.Database(SqlEndpoint, LakehouseName),\n"
            f'\t\t\t\tData = Source{{[Schema="dbo", Item="{source}"]}}[Data]\n'
            "\t\t\tin\n\t\t\t\tData\n"
        )
        parts[f"definition/tables/{table}.tmdl"] = text
    return parts


def field(table, column, measure=False):
    kind = "Measure" if measure else "Column"
    return {kind: {"Expression": {"SourceRef": {"Entity": table}}, "Property": column}}


def literal(value):
    return {"expr": {"Literal": {"Value": "'" + value.replace("'", "''") + "'"}}}


def visual(name, visual_type, title, x, y, width, height, roles):
    query_state = {}
    for role, fields in roles.items():
        query_state[role] = {"projections": [
            {"field": field(table, prop, measure), "queryRef": f"{table}.{prop}",
             "nativeQueryRef": prop}
            for table, prop, measure in fields
        ]}
    return {
        "$schema": SCHEMA_ROOT + "definition/visualContainer/2.1.0/schema.json",
        "name": name,
        "position": {"x": x, "y": y, "z": 0, "width": width,
                     "height": height, "tabOrder": 0},
        "visual": {
            "visualType": visual_type,
            "query": {"queryState": query_state},
            "visualContainerObjects": {
                "title": [{"properties": {"show": {"expr": {"Literal": {"Value": "true"}}},
                                           "text": literal(title)}}],
            },
            "drillFilterOtherVisuals": True,
        },
    }


def report_parts(model_id):
    parts = {
        "definition.pbir": {
            "$schema": SCHEMA_ROOT + "definitionProperties/2.0.0/schema.json",
            "version": "4.0",
            "datasetReference": {"byConnection": {
                "connectionString": f"semanticmodelid={model_id}",
            }},
        },
        "definition/version.json": {
            "$schema": SCHEMA_ROOT + "definition/versionMetadata/1.0.0/schema.json",
            "version": "2.0.0",
        },
        "definition/report.json": {
            "$schema": SCHEMA_ROOT + "definition/report/3.0.0/schema.json",
            "themeCollection": {},
        },
        "definition/pages/pages.json": {
            "$schema": SCHEMA_ROOT + "definition/pagesMetadata/1.0.0/schema.json",
            "pageOrder": ["usage", "reports", "coverage"], "activePageName": "usage",
        },
    }
    view = ("Report views", "Report views", True)
    viewers = ("Report views", "Unique viewers", True)
    definitions = {
        "usage": ("Report usage", [
            ("views", "card", "Report views", 20, 100, 280, 110, {"Values": [view]}),
            ("viewers", "card", "Unique viewers", 320, 100, 280, 110, {"Values": [viewers]}),
            ("active", "card", "Active reports", 620, 100, 280, 110,
             {"Values": [("Report views", "Active reports", True)]}),
            ("trend", "card", "View trend", 920, 100, 340, 110,
             {"Values": [("Report views", "View trend", True)]}),
            ("daily", "lineChart", "Report views and viewers by UTC date",
             20, 230, 800, 300, {"Category": [("Dates", "Date", False)],
                                "Y": [view, viewers]}),
            ("distribution", "clusteredBarChart", "Distribution method",
             840, 230, 420, 300,
             {"Category": [("Report views", "Distribution method", False)], "Y": [view]}),
            ("users", "tableEx", "Users with report views", 20, 550, 800, 280,
             {"Values": [("Report views", "User", False), view]}),
            ("platform", "clusteredBarChart", "Consumption method", 840, 550, 420, 280,
             {"Category": [("Report views", "Consumption method", False)], "Y": [view]}),
        ]),
        "reports": ("Report list", [
            ("reports", "tableEx", "Reports with captured activity (not a full inventory)",
             20, 120, 1240, 700, {"Values": [
                 ("Reports", "Workspace", False), ("Reports", "Report", False),
                 ("Reports", "Report identifier", False), view, viewers,
                 ("Report views", "Report rank", True),
                 ("Report views", "View trend", True),
             ]}),
        ]),
        "coverage": ("Collection coverage", [
            ("days", "card", "Completely collected UTC days", 20, 120, 380, 120,
             {"Values": [("Collection", "Collected days", True)]}),
            ("last", "card", "Last completely collected UTC date", 420, 120, 460, 120,
             {"Values": [("Collection", "Last collected date", True)]}),
            ("coverage", "tableEx",
             "Daily collection coverage - page views and load times are not available",
             20, 270, 1240, 550, {"Values": [
                 ("Collection", "Collected date", False),
                 ("Collection", "Completed", False),
             ]}),
        ]),
    }
    for page, (title, visuals) in definitions.items():
        parts[f"definition/pages/{page}/page.json"] = {
            "$schema": SCHEMA_ROOT + "definition/page/2.0.0/schema.json",
            "name": page, "displayName": title,
            "displayOption": "FitToPage", "width": 1280, "height": 850,
        }
        if page != "coverage":
            visuals = [
                ("dates", "slicer", "UTC date", 20, 10, 390, 80,
                 {"Values": [("Dates", "Date", False)]}),
                ("workspaces", "slicer", "Workspace", 430, 10, 390, 80,
                 {"Values": [("Reports", "Workspace", False)]}),
                ("report", "slicer", "Report", 840, 10, 420, 80,
                 {"Values": [("Reports", "Report", False)]}),
            ] + visuals
        for spec in visuals:
            item = visual(*spec)
            if spec[0] in ("workspaces", "report"):
                item["visual"]["objects"] = {
                    "data": [{"properties": {"mode": literal("Dropdown")}}],
                }
            parts[f"definition/pages/{page}/visuals/{spec[0]}/visual.json"] = item
    return {path: json.dumps(value) for path, value in parts.items()}


def definition(parts):
    return {"parts": [
        {"path": path, "payloadType": "InlineBase64",
         "payload": base64.b64encode(text.encode("utf-8")).decode("ascii")}
        for path, text in parts.items()
    ]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--kind", required=True, choices=["model", "report"])
    parser.add_argument("--server", default="")
    parser.add_argument("--database", default="")
    parser.add_argument("--model-id", default="")
    args = parser.parse_args()
    result = (model_parts(args.server, args.database) if args.kind == "model"
              else report_parts(args.model_id))
    print(json.dumps(definition(result)))
