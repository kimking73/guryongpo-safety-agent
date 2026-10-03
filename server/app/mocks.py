"""목업 응답 — server/mock/*.json 을 그대로 반환 (tests/test_spec.py 가 명세 스키마로 검증)

실구현으로 바뀌기 전까지 C(Flutter)·B(Agent)가 실제 서버 주소로 개발할 수 있게 한다.
응답 헤더 X-Mock: true 로 목업임을 표시. 파일은 요청마다 읽음 → 목업을 고치면 재시작 없이 반영.
"""
from __future__ import annotations

import copy
import json
from datetime import datetime, timedelta, timezone
from typing import Any

from fastapi.responses import JSONResponse

from .config import settings
from .errors import ApiError

KST = timezone(timedelta(hours=9))


def load(name: str) -> Any:
    p = settings.mock_dir / name
    if not p.is_file():
        raise ApiError("NOT_FOUND", detail=f"mock file missing: {name}")
    return json.loads(p.read_text(encoding="utf-8"))


def respond(data: Any, status: int = 200, media_type: str = "application/json") -> JSONResponse:
    return JSONResponse(copy.deepcopy(data), status_code=status, media_type=media_type, headers={"X-Mock": "true"})


def mock(name: str, status: int = 200, **overrides: Any) -> JSONResponse:
    data = load(name)
    if isinstance(data, dict):
        data.update(overrides)
    media = "application/geo+json" if name.endswith(".geojson") else "application/json"
    return respond(data, status, media)


def now_iso() -> str:
    return datetime.now(KST).isoformat(timespec="seconds")


def iso(t) -> str | None:
    if t is None:
        return None
    if isinstance(t, str):
        return t
    return t.astimezone(KST).isoformat(timespec="seconds")
