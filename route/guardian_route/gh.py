"""GraphHopper HTTP 클라이언트.

GraphHopper는 graphhopper 컨테이너(포트 8989)에서 돈다. 설정은 graphhopper/config.yml.
좌표는 이 서비스 안에서 (lat, lon) 순서로 다루고, GraphHopper에 보낼 때만 [lon, lat]로 바꾼다.
"""

from __future__ import annotations

import os
from typing import Any

import httpx

DEFAULT_URL = "http://localhost:8989"
DEFAULT_TIMEOUT_MS = 5000


class GraphHopperUnavailable(Exception):
    """GraphHopper에 연결할 수 없거나 응답이 늦거나 서버 오류를 냈다."""


class RouteNotFound(Exception):
    """GraphHopper가 경로를 못 찾았다 (도로망 범위 밖, 도로에서 너무 먼 좌표, 이어진 길 없음)."""


class GraphHopperClient:
    def __init__(self, base_url: str | None = None, timeout_ms: int | None = None,
                 transport: httpx.BaseTransport | None = None):
        # transport를 넘기면 실제 네트워크 대신 그것을 쓴다 (테스트에서 가짜 GraphHopper 주입용).
        # 인자가 없으면 환경 변수 GRAPHHOPPER_URL, GRAPHHOPPER_TIMEOUT_MS, 그다음 기본값 순으로 쓴다.
        base_url = base_url or os.environ.get("GRAPHHOPPER_URL") or DEFAULT_URL
        timeout_ms = timeout_ms or int(os.environ.get("GRAPHHOPPER_TIMEOUT_MS") or DEFAULT_TIMEOUT_MS)
        self.http = httpx.Client(base_url=base_url, timeout=timeout_ms / 1000, transport=transport)

    def route(self, points: list[tuple[float, float]], profile: str = "foot") -> dict[str, Any]:
        """(lat, lon) 좌표 목록을 순서대로 지나는 경로. GraphHopper 응답의 첫 번째 path를 돌려준다."""
        body = {
            "profile": profile,
            "points": [[lon, lat] for lat, lon in points],
            "points_encoded": True,    # geometry를 인코딩된 polyline 문자열로 받는다 (Google polyline 형식, 정밀도 1e5)
            "instructions": False,     # 회전 안내 문구는 아직 쓰지 않는다 (C5 경로 화면에서 필요하면 켠다)
        }
        try:
            res = self.http.post("/route", json=body)
        except httpx.HTTPError as e:   # 연결 실패, 시간 초과
            raise GraphHopperUnavailable(f"경로 엔진에 연결할 수 없습니다: {type(e).__name__}") from e
        if res.status_code >= 500:
            raise GraphHopperUnavailable(f"경로 엔진 오류 (HTTP {res.status_code})")
        data = _json(res)
        if res.status_code >= 400 or not data.get("paths"):
            raise RouteNotFound(data.get("message") or f"HTTP {res.status_code}")
        return data["paths"][0]

    def ping(self) -> bool:
        """GraphHopper가 살아 있으면 True. 예외를 내지 않는다."""
        try:
            return self.http.get("/health").status_code == 200
        except httpx.HTTPError:
            return False


def _json(res: httpx.Response) -> dict[str, Any]:
    try:
        data = res.json()
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}
