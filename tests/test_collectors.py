"""Tests for the two collector functions in collection-stack.yaml.

Run from the repository root:  python3 -m unittest discover -s tests -v
Requires only PyYAML (see tests/requirements.txt).
"""
import json
import unittest

import harness as h

KEY = f"investigations-v2/account_id={h.ACCOUNT}/region={h.REGION}/agentspace_id=as-1/exe-ops1-1.json"
TAGGED = {"agentSpace": {"name": "notification-service"}, "tags": {"workload": "payments"}}
UNTAGGED = {"agentSpace": {"name": "notification-service"}, "tags": {}}


class InvestigationCollectorTests(unittest.TestCase):

    def run_collector(self, evt, info=TAGGED, journal=None, fail=()):
        agent = h.FakeAgent(spaces={"as-1": info}, journal=journal if journal is not None else h.journal(),
                            fail=fail)
        ns, s3 = h.load_function("CollectorFunction", agent)
        return ns, s3, ns["handler"](evt, None)

    def test_completed_record_key_and_fields(self):
        _, s3, _ = self.run_collector(h.event())
        record = json.loads(s3.body(KEY))
        self.assertEqual(record["status"], "COMPLETED")
        self.assertEqual(record["durationMinutes"], 8.8)
        self.assertEqual(record["agentSpaceRegion"], h.REGION)
        self.assertEqual(record["accountId"], h.ACCOUNT)
        self.assertTrue(record["resolved"])
        self.assertEqual(record["investigationDate"], "2026-07-24")
        self.assertIn(f"region={h.REGION}", record["consoleUrl"])

    def test_record_has_no_field_named_region(self):
        # A data field named like a key segment would clash with any future partitioning.
        _, s3, _ = self.run_collector(h.event())
        self.assertNotIn("region", json.loads(s3.body(KEY)))

    def test_rerun_is_idempotent(self):
        agent = h.FakeAgent(spaces={"as-1": TAGGED}, journal=h.journal())
        ns, s3 = h.load_function("CollectorFunction", agent)
        ns["handler"](h.event(), None)
        first = s3.body(KEY)
        ns["handler"](h.event(), None)
        self.assertEqual(list(s3.objects), [KEY])
        self.assertEqual(s3.body(KEY), first)

    def test_workload_label_precedence(self):
        cases = [(TAGGED, "payments"), (UNTAGGED, "notification-service"),
                 ({"agentSpace": {"name": "data-pipeline"}, "tags": {"workload": "  "}}, "data-pipeline")]
        for info, expected in cases:
            with self.subTest(expected=expected):
                _, s3, _ = self.run_collector(h.event(), info=info)
                self.assertEqual(json.loads(s3.body(KEY))["workloadName"], expected)

    def test_unreadable_agent_space_still_writes_record(self):
        _, s3, _ = self.run_collector(h.event(), fail={"get_agent_space"})
        self.assertEqual(json.loads(s3.body(KEY))["workloadName"], "unknown")

    def test_failed_investigation_writes_status_only(self):
        _, s3, _ = self.run_collector(h.event("Investigation Failed", status="FAILED"), journal=[])
        record = json.loads(s3.body(KEY))
        self.assertEqual(record["status"], "FAILED")
        self.assertFalse(record["resolved"])
        self.assertNotIn("durationMinutes", record)
        self.assertEqual(record["investigationDate"], "2026-07-24")

    def test_timed_out_without_execution_id_keys_on_task(self):
        evt = h.event("Investigation Timed Out", status="TIMED_OUT", execution_id=None)
        _, s3, result = self.run_collector(evt, journal=[])
        self.assertTrue(result["key"].endswith("/task-task-1.json"))
        self.assertEqual(json.loads(s3.body(result["key"]))["status"], "TIMED_OUT")

    def test_status_falls_back_to_detail_type(self):
        evt = h.event("Investigation Failed", status="FAILED")
        del evt["detail"]["data"]["status"]
        _, s3, _ = self.run_collector(evt, journal=[])
        self.assertEqual(json.loads(s3.body(KEY))["status"], "FAILED")

    def test_journal_error_raises_so_lambda_retries(self):
        with self.assertRaises(RuntimeError):
            self.run_collector(h.event(), fail={"list_journal_records"})

    def test_missing_summary_raises_named_error(self):
        agent = h.FakeAgent(spaces={"as-1": TAGGED}, journal=h.journal()[:2])
        ns, s3 = h.load_function("CollectorFunction", agent)
        with self.assertRaises(ns["NoInvestigationSummary"]):
            ns["handler"](h.event(), None)
        self.assertEqual(s3.objects, {})

    def test_event_without_ids_raises(self):
        evt = h.event()
        evt["detail"]["metadata"] = {}
        with self.assertRaises(ValueError):
            self.run_collector(evt)


class InventoryCollectorTests(unittest.TestCase):
    STATUS = f"collector-status/account_id={h.ACCOUNT}/region={h.REGION}/status.json"

    def rec_key(self, space):
        return f"recommendations-v1/account_id={h.ACCOUNT}/region={h.REGION}/agentspace_id={space}/current.json"

    def run_inventory(self, agent, s3=None, depth=0):
        ns, s3 = h.load_function("InventoryFunction", agent, s3=s3, sqs=h.FakeSqs(depth))
        return ns, s3

    def test_no_agent_spaces_reports_idle(self):
        ns, s3 = self.run_inventory(h.FakeAgent())
        ns["handler"]({}, None)
        status = json.loads(s3.body(self.STATUS))
        self.assertEqual(status["status"], "NO_AGENT_SPACES")
        self.assertEqual(status["agentSpaceCount"], 0)
        self.assertEqual(status["agentSpaceRegion"], h.REGION)

    def test_active_writes_recommendations_and_status(self):
        rec = {"recommendationId": "r1", "title": "Add alarm", "status": "PROPOSED", "priority": "MEDIUM",
               "taskId": "eval-as-1"}
        ns, s3 = self.run_inventory(h.FakeAgent(spaces={"as-1": TAGGED}, recommendations={"as-1": [rec]}),
                                    depth=3)
        ns["handler"]({}, None)
        status = json.loads(s3.body(self.STATUS))
        self.assertEqual((status["status"], status["agentSpaceCount"], status["recommendationCount"]),
                         ("ACTIVE", 1, 1))
        self.assertEqual(status["failedEventsPending"], 3)
        row = json.loads(s3.body(self.rec_key("as-1")))
        self.assertEqual((row["workloadName"], row["accountId"], row["agentSpaceRegion"]),
                         ("payments", h.ACCOUNT, h.REGION))

    def test_agent_space_without_recommendations_gets_placeholder(self):
        ns, s3 = self.run_inventory(h.FakeAgent(spaces={"as-1": UNTAGGED}))
        ns["handler"]({}, None)
        row = json.loads(s3.body(self.rec_key("as-1")))
        self.assertEqual((row["recommendationId"], row["workloadName"]), ("none", "notification-service"))

    def test_deleted_agent_space_recommendations_removed(self):
        s3 = h.FakeS3()
        s3.put_object("bucket", self.rec_key("as-gone"), "{}")
        ns, s3 = self.run_inventory(h.FakeAgent(spaces={"as-1": TAGGED}), s3=s3)
        ns["handler"]({}, None)
        self.assertIn(self.rec_key("as-gone"), s3.deleted)
        self.assertIn(self.rec_key("as-1"), s3.objects)
        self.assertEqual(json.loads(s3.body(self.STATUS))["removedAgentSpaces"], 1)

    def test_listing_failure_never_deletes_and_reports_error(self):
        s3 = h.FakeS3()
        s3.put_object("bucket", self.rec_key("as-1"), "{}")
        ns, s3 = self.run_inventory(h.FakeAgent(spaces={"as-1": TAGGED}, fail={"list_agent_spaces"}), s3=s3)
        with self.assertRaises(RuntimeError):
            ns["handler"]({}, None)
        self.assertEqual(s3.deleted, [])
        status = json.loads(s3.body(self.STATUS))
        self.assertEqual(status["status"], "ERROR")
        self.assertIsNone(status["agentSpaceCount"])
        self.assertIn("ListAgentSpaces", status["errorMessage"])

    def test_replication_failures_counted(self):
        s3 = h.FakeS3()
        key = f"investigations-v2/account_id={h.ACCOUNT}/region={h.REGION}/agentspace_id=as-1/e.json"
        s3.put_object("bucket", key, "{}")
        s3.objects[key]["ReplicationStatus"] = "FAILED"
        ns, s3 = self.run_inventory(h.FakeAgent(), s3=s3)
        ns["handler"]({}, None)
        self.assertEqual(json.loads(s3.body(self.STATUS))["replicationFailures"], 1)


class TemplateTests(unittest.TestCase):

    def test_inline_template_fits_create_stack_set_limit(self):
        # CloudFormation's TemplateBody limit is 51,200 bytes; above it a StackSet
        # needs a template URL in S3 instead of the file itself.
        self.assertLess(h.TEMPLATE.stat().st_size, 51_200)

    def test_region_scoped_names(self):
        res = h.load_template()["Resources"]
        for logical_id in ("ReplicationRole", "CollectorRole", "InventoryRole"):
            with self.subTest(role=logical_id):
                self.assertIn("RoleName", res[logical_id]["Properties"])


if __name__ == "__main__":
    unittest.main()
