#!/usr/bin/env python3
"""Validate TDD links, schemas and examples; does not execute product logic."""
from __future__ import annotations

import copy
import datetime as dt
import importlib.metadata
import json
from pathlib import Path
import re

from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parents[1]
CHECKER = FormatChecker()
UTC_PATTERN = r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z"


@CHECKER.checks("date-time", raises=(ValueError, TypeError))
def check_datetime(value):
    if not isinstance(value, str):
        return True
    if not re.fullmatch(UTC_PATTERN, value):
        return False
    dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    return True


@CHECKER.checks("date", raises=(ValueError, TypeError))
def check_date(value):
    if not isinstance(value, str):
        return True
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        return False
    dt.date.fromisoformat(value)
    return True


def read(relative):
    return json.loads((ROOT / relative).read_text())


def require(condition, label):
    if not condition:
        raise AssertionError(label)


def main():
    checks = []
    for path in ROOT.rglob("*.md"):
        text = path.read_text()
        require(text.count("```") % 2 == 0, f"Code fence: {path}")
        for target in re.findall(r"\]\(([^)]+)\)", text):
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            local = target.split("#", 1)[0]
            require(not local or (path.parent / local).exists(), f"Link: {path}: {target}")
    checks.append({"check": "markdown-local-links-and-fences", "result": "PASS"})
    validators = {}
    for name in ("ai-proposal", "error"):
        schema = read(f"contracts/{name}.schema.json")
        Draft202012Validator.check_schema(schema)
        validators[name] = Draft202012Validator(schema, format_checker=CHECKER)
    checks.append({"check": "draft-2020-12-schema-validity", "result": "PASS"})
    cases = (
        ("proposal-create-valid.json", "ai-proposal", True),
        ("proposal-review-valid.json", "ai-proposal", True),
        ("proposal-extra-field-invalid.json", "ai-proposal", False),
        ("error-valid.json", "error", True),
    )
    for filename, schema, expected in cases:
        actual = validators[schema].is_valid(read(f"contracts/examples/{filename}"))
        require(actual == expected, f"Unexpected validity: {filename}")
        checks.append({"check": filename, "expectedValid": expected, "result": "PASS"})
    base = read("contracts/examples/proposal-create-valid.json")
    mutations = (
        ("reject-invalid-uuid", lambda d: d.__setitem__("proposalId", "not-a-uuid")),
        ("reject-impossible-date-time", lambda d: d.__setitem__("createdAt", "2026-13-40T99:00:00.000Z")),
        ("reject-non-utc-date-time", lambda d: d.__setitem__("createdAt", "2026-11-10T09:00:00.000+08:00")),
        ("reject-unknown-schema-version", lambda d: d.__setitem__("schemaVersion", "99.0")),
        ("reject-blank-title", lambda d: d["operations"][0].__setitem__("title", "")),
        ("reject-extra-deadline-fields", lambda d: d["operations"][0]["deadline"].__setitem__("instant", "2026-11-10T00:00:00.000Z")),
    )
    for label, mutate in mutations:
        data = copy.deepcopy(base)
        mutate(data)
        require(not validators["ai-proposal"].is_valid(data), label)
        checks.append({"check": label, "result": "PASS"})
    for date, expected in (("2026-02-28", True), ("2026-02-30", False)):
        data = copy.deepcopy(base)
        data["operations"][0]["deadline"] = {
            "kind": "DATE", "localDate": date, "zoneId": "Asia/Shanghai",
            "source": "EXPLICIT", "originalExpression": date,
        }
        require(validators["ai-proposal"].is_valid(data) == expected, f"Date: {date}")
        checks.append({"check": f"date-{date}", "expectedValid": expected, "result": "PASS"})
    semantic = read("contracts/examples/semantic-cases.json")
    for case in semantic["cases"]:
        example = read(f"contracts/examples/{case['example']}")
        require(validators["ai-proposal"].is_valid(example), case["id"])
    checks.append({"check": "semantic-case-schema-precondition", "result": "PASS",
                   "cases": len(semantic["cases"]), "domainExecution": "NOT_RUN"})
    index = (ROOT / "README.md").read_text()
    for number in range(17):
        require(re.search(rf"\| M{number:02d} \|", index), f"Module M{number:02d}")
    release = (ROOT / "08-实施与验收.md").read_text()
    for number in range(1, 23):
        require(f"RC{number:02d} " in release, f"Release RC{number:02d}")
    checks.append({"check": "module-and-release-coverage", "result": "PASS",
                   "modules": 17, "releaseCriteria": 22})
    report = {
        "documentDate": "2026-11-10",
        "checkedAtUtc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "scope": "文档与契约示例；不代表业务逻辑或平台已实现/通过",
        "validator": "jsonschema " + importlib.metadata.version("jsonschema"),
        "dateTimeAssertion": "explicit UTC millisecond pattern + datetime parser",
        "checks": checks,
        "notRun": ["领域语义执行", "原生编译/真机", "数据库迁移", "模型/ASR/密钥适配器",
                   "Hosted并发账本", "真实购买与商店审核", "端到端应用旅程"],
    }
    (ROOT / "交付校验记录.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"PASS: {len(checks)} document/contract checks; domain/platform execution NOT RUN")


if __name__ == "__main__":
    main()
