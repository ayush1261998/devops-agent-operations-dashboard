"""Offline test harness for the inline Lambda code in collection-stack.yaml.

The collector functions live only inline in the template (that is the single copy
CloudFormation deploys). This harness extracts that code and runs it against
in-memory fakes of the S3, SQS, and DevOps Agent clients, so tests exercise the
exact code that ships. No AWS credentials or network access are used.
"""
import json
import os
import sys
import types
from datetime import datetime, timedelta, timezone
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "source" / "collection" / "collection-stack.yaml"
ACCOUNT, REGION = "111111111111", "us-west-2"


class _CfnLoader(yaml.SafeLoader):
    pass


# Intrinsic functions (!Ref, !Sub, ...) are irrelevant to the Python code.
_CfnLoader.add_multi_constructor("!", lambda loader, suffix, node: None)


def load_template():
    return yaml.load(TEMPLATE.read_text(), Loader=_CfnLoader)


def function_code(logical_id):
    return load_template()["Resources"][logical_id]["Properties"]["Code"]["ZipFile"]


class ClientError(Exception):
    pass


class FakeS3:
    def __init__(self):
        self.objects = {}          # key -> {"Body":..., "LastModified":..., "ReplicationStatus":...}
        self.deleted = []

    def put_object(self, Bucket, Key, Body, **_):
        body = Body.decode() if isinstance(Body, bytes) else Body
        self.objects[Key] = {"Body": body, "LastModified": datetime.now(timezone.utc),
                             "ReplicationStatus": "COMPLETED"}

    def delete_object(self, Bucket, Key):
        self.deleted.append(Key)
        self.objects.pop(Key, None)

    def head_object(self, Bucket, Key):
        if Key not in self.objects:
            raise ClientError("404")
        return {"ReplicationStatus": self.objects[Key]["ReplicationStatus"]}

    def get_paginator(self, name):
        s3 = self

        class _Paginator:
            def paginate(self, Bucket, Prefix):
                yield {"Contents": [{"Key": k, "LastModified": v["LastModified"]}
                                    for k, v in sorted(s3.objects.items()) if k.startswith(Prefix)]}
        return _Paginator()

    def body(self, key):
        return self.objects[key]["Body"]


class FakeSqs:
    def __init__(self, depth=0):
        self.depth = depth

    def get_queue_attributes(self, QueueUrl, AttributeNames):
        return {"Attributes": {"ApproximateNumberOfMessages": str(self.depth)}}


class FakeAgent:
    """Minimal DevOps Agent API. Configure the attributes a test needs."""

    def __init__(self, spaces=None, journal=None, recommendations=None, fail=()):
        self.spaces = spaces or {}            # id -> GetAgentSpace response
        self.journal = journal or []
        self.recommendations = recommendations or {}   # id -> list
        self.fail = set(fail)                  # method names that raise

    def _maybe_fail(self, name):
        if name in self.fail:
            raise RuntimeError(f"{name} failed")

    def get_agent_space(self, agentSpaceId):
        self._maybe_fail("get_agent_space")
        return self.spaces.get(agentSpaceId, {})

    def list_journal_records(self, **_):
        self._maybe_fail("list_journal_records")
        return {"records": self.journal}

    def list_agent_spaces(self, **_):
        self._maybe_fail("list_agent_spaces")
        return {"agentSpaces": [{"agentSpaceId": i} for i in self.spaces]}

    def list_goals(self, agentSpaceId):
        return {"goals": [{"lastSuccessfulTaskId": f"eval-{agentSpaceId}"}]}

    def list_recommendations(self, agentSpaceId, taskId, **_):
        return {"recommendations": self.recommendations.get(agentSpaceId, [])}


def load_function(logical_id, agent, s3=None, sqs=None):
    """Execute the inline code with fake clients; returns (module namespace, s3)."""
    s3 = s3 or FakeS3()
    sqs = sqs or FakeSqs()
    fake_boto3 = types.ModuleType("boto3")
    fake_boto3.client = lambda name, **_: {"s3": s3, "sqs": sqs}.get(name, agent)
    fake_config = types.ModuleType("botocore.config")
    fake_config.Config = lambda **kw: kw
    fake_exceptions = types.ModuleType("botocore.exceptions")
    fake_exceptions.ClientError = ClientError
    fake_botocore = types.ModuleType("botocore")
    sys.modules.update({"boto3": fake_boto3, "botocore": fake_botocore,
                        "botocore.config": fake_config, "botocore.exceptions": fake_exceptions})
    os.environ.update(COLLECTION_BUCKET="bucket", ACCOUNT_ID=ACCOUNT, AWS_REGION=REGION,
                      SOLUTION_VERSION="1.0.0", FAILED_EVENTS_QUEUE_URL="https://sqs/queue")
    namespace = {"__name__": f"collector_{logical_id}"}
    exec(compile(function_code(logical_id), f"<{logical_id}>", "exec"), namespace)
    return namespace, s3


def event(detail_type="Investigation Completed", status="COMPLETED", execution_id="exe-ops1-1",
          space="as-1", priority="HIGH"):
    metadata = {"agent_space_id": space, "task_id": "task-1"}
    if execution_id:
        metadata["execution_id"] = execution_id
    return {"source": "aws.aidevops", "detail-type": detail_type, "time": "2026-07-24T19:20:00Z",
            "detail": {"version": "1.0.0", "metadata": metadata,
                       "data": {"task_type": "INVESTIGATION", "priority": priority, "status": status,
                                "updated_at": "2026-07-24T19:14:07Z"}}}


def journal(minutes=8, seconds=46, root_cause=True):
    start = datetime(2026, 7, 24, 19, 5, 21, tzinfo=timezone.utc)
    end = start + timedelta(minutes=minutes, seconds=seconds)
    findings = [{"type": "root_cause", "title": "Throttled table", "description": "d",
                 "related_resources": ["Workload Table"]}] if root_cause else \
               [{"type": "cause", "title": "Possible cause", "related_resources": ["Queue"]}]
    summary = {"symptoms": [{"title": "Latency"}], "findings": findings,
               "investigation_gaps": [{"title": "No logs"}]}
    util = {"data": {"context_window": {"utilization": 31.0, "compaction_count": 0},
                     "subagents": [{"id": "logs"}], "tools": [{"tool_use_count": 5}]}}
    return [{"recordType": "start", "createdAt": start},
            {"recordType": "utilization", "createdAt": start, "content": json.dumps(util)},
            {"recordType": "investigation_summary", "createdAt": end, "content": json.dumps(summary)}]
