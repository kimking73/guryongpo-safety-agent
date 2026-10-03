"""명세(server/spec/openapi.yaml) 자체 검사 + 목업 JSON 이 명세 응답 스키마를 지키는지 (v0.3~)

C·B 는 목업으로 먼저 개발하므로, 목업이 명세와 어긋나면 실구현 때 화면이 깨진다 → 명세나 목업을 고치면 이 테스트가 잡는다.
"""
import json
import re
from pathlib import Path

import pytest

yaml = pytest.importorskip("yaml")
jsonschema = pytest.importorskip("jsonschema", minversion="4.18")     # Draft 2020-12

from spec_mocks import MOCK_SCHEMAS  # noqa: E402

SERVER = Path(__file__).resolve().parent.parent
SPEC = yaml.safe_load((SERVER / "spec" / "openapi.yaml").read_text(encoding="utf-8"))
MOCK_DIR = SERVER / "mock"


def _resolve(ref: str):
    node = SPEC
    for part in ref.lstrip("#/").split("/"):
        node = node[part]
    return node


def test_refs_and_path_params():
    bad = []

    def walk(o):
        if isinstance(o, dict):
            for k, v in o.items():
                if k == "$ref":
                    try:
                        _resolve(v)
                    except KeyError:
                        bad.append(v)
                else:
                    walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(SPEC)
    ids = set()
    for path, item in SPEC["paths"].items():
        need = set(re.findall(r"{(\w+)}", path))
        common = {p.get("name") for p in item.get("parameters", [])}
        for method, op in item.items():
            if method in ("parameters", "servers"):
                continue
            assert op["operationId"] not in ids, op["operationId"]
            ids.add(op["operationId"])
            have = common | {p.get("name") or _resolve(p["$ref"])["name"] for p in op.get("parameters", [])}
            assert need <= have, (method, path, need - have)
            assert "responses" in op, (method, path)
    assert not bad, bad


def test_schemas_are_valid_json_schema():
    for name, schema in SPEC["components"]["schemas"].items():
        jsonschema.Draft202012Validator.check_schema(schema)


def test_every_mock_file_is_mapped():
    files = {p.name for p in MOCK_DIR.iterdir() if p.suffix in (".json", ".geojson")}
    assert files == set(MOCK_SCHEMAS), (files ^ set(MOCK_SCHEMAS))


@pytest.mark.parametrize("name", sorted(MOCK_SCHEMAS))
def test_mock_matches_spec(name):
    path, method, status, ctype = MOCK_SCHEMAS[name]
    schema = SPEC["paths"][path][method]["responses"][status]["content"][ctype]["schema"]
    root = {**SPEC, **schema}          # $ref 가 문서 전체 기준으로 풀리도록
    data = json.loads((MOCK_DIR / name).read_text(encoding="utf-8"))
    v = jsonschema.Draft202012Validator(root, format_checker=jsonschema.Draft202012Validator.FORMAT_CHECKER)
    errors = [f"{e.json_path}: {e.message}" for e in v.iter_errors(data)]
    assert not errors, errors[:5]


def test_routes_match_spec():
    """FastAPI 에 등록된 /api/v1 경로 = 명세의 api 경로 (ai·route 서비스 경로 제외)"""
    from app.main import app
    served = set()
    for p, item in app.openapi()["paths"].items():          # FastAPI 가 만든 명세 (버전에 상관없이 등록 경로 전체)
        if p.startswith("/api/v1/"):
            served |= {(m, p[len("/api/v1"):]) for m in item}
    spec = {(m, p) for p, item in SPEC["paths"].items() if not p.startswith("/api/")
            for m in item if m not in ("parameters", "servers")}
    assert served == spec, {"코드에만": sorted(served - spec), "명세에만": sorted(spec - served)}
