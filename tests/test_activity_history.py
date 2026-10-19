import importlib.util
import json
from datetime import date, timedelta
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


collector = load("collector", "src/notebook/usage_metrics_history.py")
artifacts = load("artifacts", "src/build_artifacts.py")


class Response:
    def __init__(self, body, status=200, headers=None):
        self.body = body
        self.status_code = status
        self.headers = headers or {}

    def json(self):
        return self.body

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(str(self.status_code))


class Session:
    def __init__(self, responses):
        self.responses = iter(responses)
        self.calls = []

    def get(self, url, **kwargs):
        self.calls.append((url, kwargs))
        return next(self.responses)


class CollectorTests(unittest.TestCase):
    today = date(2026, 10, 19)

    def test_collector_identity_matches_pinned_tenant_and_user(self):
        claims = {"tid": "tenant", "oid": "user", "scp": "user_impersonation"}
        self.assertEqual(
            collector.validate_collector_identity(claims, "TENANT", "USER"), "tenant"
        )
        self.assertEqual(collector.validate_collector_identity(claims), "tenant")

    def test_collector_identity_rejects_wrong_runtime_user_or_tenant(self):
        claims = {"tid": "tenant", "oid": "user", "scp": "user_impersonation"}
        for tenant, user in (("other", "user"), ("tenant", "other")):
            with self.assertRaises(PermissionError):
                collector.validate_collector_identity(claims, tenant, user)
        for invalid in ({}, {"tid": "tenant"}, {"tid": "tenant", "oid": "user"},
                        dict(claims, idtyp="app")):
            with self.assertRaises(PermissionError):
                collector.validate_collector_identity(invalid)

    def test_initial_backfill_is_within_28_day_api_window(self):
        days = collector.days_to_fetch(self.today, set(), 27, 3)
        self.assertEqual(len(days), 27)
        self.assertEqual(days[0], self.today - timedelta(days=27))
        self.assertEqual(days[-1], self.today - timedelta(days=1))

    def test_replay_and_missing_days(self):
        complete = {self.today - timedelta(days=i) for i in range(1, 20)}
        missing = self.today - timedelta(days=12)
        complete.remove(missing)
        days = collector.days_to_fetch(self.today, complete, 27, 3)
        self.assertEqual(set(days), {
            missing, self.today - timedelta(days=1),
            self.today - timedelta(days=2), self.today - timedelta(days=3),
        })

    def test_exact_retention_and_forever(self):
        cutoff = collector.retention_cutoff(self.today, 730)
        self.assertEqual((self.today - cutoff).days + 1, 730)
        self.assertIsNone(collector.retention_cutoff(self.today, 0))
        with self.assertRaises(ValueError):
            collector.retention_cutoff(self.today, -1)

    def test_backfill_bounds(self):
        for backfill, replay in ((28, 3), (0, 3), (27, 0), (27, 28)):
            with self.assertRaises(ValueError):
                collector.days_to_fetch(self.today, set(), backfill, replay)

    def event(self, **values):
        return {
            "Id": "event-1", "Activity": "ViewReport", "CreationTime": "2026-10-18T12:00:00Z",
            "OrganizationId": "tenant", "ReportId": "report", "WorkspaceId": "workspace",
            "WorkSpaceName": "Workspace", "UserId": "User@example.invalid",
            "UserKey": "key", "ClientIP": "not retained", **values,
        }

    def test_pseudonymization_and_minimal_raw_schema(self):
        row = collector.normalize_event(self.event(), "tenant", date(2026, 10, 18), False)
        self.assertEqual(len(row["UserId"]), 64)
        self.assertNotIn("ClientIP", row)
        self.assertEqual(row["WorkspaceName"], "Workspace")
        self.assertEqual(row["EventKey"], "tenant:event-1")
        self.assertEqual(
            row["UserId"],
            collector.normalize_event(self.event(UserId=" user@EXAMPLE.invalid "),
                                      "tenant", date(2026, 10, 18), False)["UserId"],
        )

    def test_identity_opt_in_and_stable_event_key(self):
        a = collector.normalize_event(self.event(), "tenant", date(2026, 10, 18), True)
        b = collector.normalize_event(self.event(), "tenant", date(2026, 10, 18), True)
        self.assertEqual(a, b)
        self.assertEqual(a["UserId"], "User@example.invalid")

    def test_wrong_tenant_date_and_invalid_event_fail(self):
        for changes in ({"OrganizationId": "other"}, {"CreationTime": "2026-10-17T00:00:00Z"},
                        {"Id": None}, {"Activity": "DeleteReport"}):
            with self.assertRaises(ValueError):
                collector.normalize_event(self.event(**changes), "tenant",
                                          date(2026, 10, 18), False)

    def test_timestamp_is_validated_in_utc(self):
        row = collector.normalize_event(
            self.event(CreationTime="2026-10-19T01:00:00+02:00"),
            "tenant", date(2026, 10, 18), False,
        )
        self.assertEqual(row["EventDate"], date(2026, 10, 18))

    def test_network_timeout_is_retried(self):
        from requests.exceptions import Timeout

        class FlakySession(Session):
            def get(self, url, **kwargs):
                if not self.calls:
                    self.calls.append((url, kwargs))
                    raise Timeout()
                return super().get(url, **kwargs)

        sleeps = []
        session = FlakySession([Response({"activityEventEntities": []})])
        result = collector.ActivityClient(
            lambda: "test", session=session, sleep=sleeps.append
        ).get({})
        self.assertEqual(result["activityEventEntities"], [])
        self.assertEqual(sleeps, [5])

    def test_empty_page_does_not_stop_pagination(self):
        session = Session([
            Response({"activityEventEntities": [], "continuationToken": "abc%2Bdef"}),
            Response({"activityEventEntities": [self.event()]}),
        ])
        client = collector.ActivityClient(lambda: "test", session=session)
        pages = list(client.pages(date(2026, 10, 18)))
        self.assertEqual([len(p) for p in pages], [0, 1])
        self.assertEqual(session.calls[1][1]["params"], {"continuationToken": "'abc+def'"})
        self.assertIn("startDateTime", session.calls[0][1]["params"])

    def test_repeated_token_fails(self):
        session = Session([Response({"activityEventEntities": [], "continuationToken": "same"})] * 2)
        with self.assertRaises(ValueError):
            list(collector.ActivityClient(lambda: "test", session=session).pages(self.today))

    def test_permissions_fail_without_retry(self):
        for code in (401, 403):
            session = Session([Response({}, code)])
            with self.assertRaises(PermissionError):
                collector.ActivityClient(lambda: "test", session=session).get({})
            self.assertEqual(len(session.calls), 1)

    def test_retry_after_and_malformed_response(self):
        sleeps = []
        session = Session([Response({}, 429, {"Retry-After": "7"}),
                           Response({"activityEventEntities": []})])
        collector.ActivityClient(lambda: "test", session=session, sleep=sleeps.append).get({})
        self.assertEqual(sleeps, [7])
        with self.assertRaises(ValueError):
            collector.ActivityClient(lambda: "test", session=Session([Response({})])).get({})


class ArtifactTests(unittest.TestCase):
    def test_workspace_and_report_filters_are_dropdowns(self):
        parts = {k: json.loads(v) for k, v in artifacts.report_parts("model-id").items()}
        for page in ("usage", "reports"):
            for name, column in (("workspaces", "Workspace"), ("report", "Report")):
                visual = parts[f"definition/pages/{page}/visuals/{name}/visual.json"]["visual"]
                self.assertEqual(visual["visualType"], "slicer")
                self.assertEqual(visual["objects"]["data"][0]["properties"]["mode"],
                                 artifacts.literal("Dropdown"))
                projection = visual["query"]["queryState"]["Values"]["projections"][0]
                self.assertEqual(projection["field"], artifacts.field("Reports", column))
                self.assertTrue(visual["drillFilterOtherVisuals"])
            dates = parts[f"definition/pages/{page}/visuals/dates/visual.json"]["visual"]
            self.assertNotIn("objects", dates)
        self.assertNotIn("definition/pages/coverage/visuals/workspaces/visual.json", parts)
        self.assertNotIn("definition/pages/coverage/visuals/report/visual.json", parts)

    def test_no_template_or_xmla_source(self):
        parts = artifacts.model_parts("server", "lakehouse")
        self.assertEqual(len([p for p in parts if "/tables/" in p]), 4)
        self.assertNotIn("powerbi://", "".join(parts.values()))
        for table, (source, columns) in artifacts.TABLES.items():
            text = parts[f"definition/tables/{table}.tmdl"]
            self.assertIn(f'Item="{source}"', text)
            for _, column, _, _ in columns:
                self.assertIn(f"sourceColumn: {column}", text)
        self.assertIn("ALLSELECTED('Reports')", parts["definition/tables/Report views.tmdl"])

    def test_visual_references_and_bounds(self):
        parts = {k: json.loads(v) for k, v in artifacts.report_parts("model-id").items()}
        allowed = {t: {c[0] for c in cols} for t, (_, cols) in artifacts.TABLES.items()}
        for table, measures in artifacts.MEASURES.items():
            allowed[table].update(m[0] for m in measures)
        for path, item in parts.items():
            if not path.endswith("/visual.json"):
                continue
            position = item["position"]
            self.assertLessEqual(position["x"] + position["width"], 1280)
            self.assertLessEqual(position["y"] + position["height"], 850)
            for role in item["visual"]["query"]["queryState"].values():
                for projection in role["projections"]:
                    ref = next(iter(projection["field"].values()))
                    table = ref["Expression"]["SourceRef"]["Entity"]
                    self.assertIn(ref["Property"], allowed[table])
        self.assertEqual(parts["definition/pages/pages.json"]["pageOrder"],
                         ["usage", "reports", "coverage"])
        text = json.dumps(parts).lower()
        self.assertNotIn('"report load times"', text)
        self.assertNotIn('"report page views"', text)


if __name__ == "__main__":
    unittest.main()
