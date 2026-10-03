"""명세(server/spec/openapi.yaml) ↔ 목업(server/mock/) 검증 — pytest 없이 빠르게 확인할 때

  cd server/tools && python3 validate.py
대응표는 tests/spec_mocks.py 하나만 고친다 (tests/test_spec.py 와 같은 표).
"""
import json
import re
import sys
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator

SERVER = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SERVER / "tests"))
from spec_mocks import MOCK_SCHEMAS  # noqa: E402

d = yaml.safe_load((SERVER / "spec" / "openapi.yaml").read_text(encoding="utf-8"))
errs = []


def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == "$ref":
                t = d
                try:
                    for x in v.lstrip("#/").split("/"):
                        t = t[x]
                except KeyError:
                    errs.append("bad ref " + v)
            else:
                walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)


walk(d)
ops = 0
for p, item in d["paths"].items():
    need = set(re.findall(r"{(\w+)}", p))
    common = {x["name"] for x in item.get("parameters", []) if "name" in x}
    for m, op in item.items():
        if m in ("parameters", "servers"):
            continue
        ops += 1
        have = common | {x.get("name") or d["components"]["parameters"][x["$ref"].split("/")[-1]]["name"]
                         for x in op.get("parameters", [])}
        if need - have:
            errs.append(f"{m} {p} missing {need - have}")
print(len(d["paths"]), "paths", ops, "operations; structural errors:", errs or "none")

bad = 0
mock_dir = SERVER / "mock"
unmapped = {f.name for f in mock_dir.iterdir() if f.suffix in (".json", ".geojson")} - set(MOCK_SCHEMAS)
if unmapped:
    print("대응표에 없는 목업:", sorted(unmapped))
    bad += 1
for f, (p, m, s, ct) in sorted(MOCK_SCHEMAS.items()):
    sch = d["paths"][p][m]["responses"][s]["content"][ct]["schema"]
    v = Draft202012Validator({**d, **sch}, format_checker=Draft202012Validator.FORMAT_CHECKER)
    es = list(v.iter_errors(json.loads((mock_dir / f).read_text(encoding="utf-8"))))
    print(("OK  " if not es else "FAIL"), f, *[f"\n    {e.json_path}: {e.message[:120]}" for e in es[:5]])
    bad += bool(es)
ri = {**d, "$ref": "#/components/schemas/RiskItem"}
for ft in json.loads((mock_dir / "risk-areas.geojson").read_text(encoding="utf-8"))["features"]:
    for e in Draft202012Validator(ri).iter_errors(ft["properties"]):
        print("RiskItem FAIL", e.message)
        bad += 1
print("mock failures:", bad)
sys.exit(1 if bad or errs else 0)
