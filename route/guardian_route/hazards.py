"""경로에서 피할 위험 구역 (침수·산사태).

기본: A의 위험 판정 엔진이 지금 발효 중으로 낸 영역(api `GET /api/v1/risk/areas`) — 앱 지도에 칠해지는 영역과 같다.
  침수·산사태 중 "주의" 이상만 피한다. 호우 영역은 구룡포읍 전체(반경 4km)라 넣으면 모든 길이 막혀 뺀다.
ROUTE_HAZARDS_FILE을 주면 그 GeoJSON 파일(시연·테스트용 고정 구역, 예: route/data/hazards.sample.geojson)을 쓴다.
맨홀은 회피하지 않는다 (사용자 결정 2026-10-02). 파일에 맨홀이 있어도 무시한다.
좌표는 GeoJSON 규칙대로 [lon, lat].
"""

from __future__ import annotations

import json
import logging
import math
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal, Protocol

import httpx
from shapely.geometry import Polygon, mapping, shape
from shapely.geometry.base import BaseGeometry

log = logging.getLogger("guardian_route")

HazardKind = Literal["flood", "landslide"]
AVOID_KINDS = ("flood", "landslide")

SAMPLE_FILE = Path(__file__).resolve().parent.parent / "data" / "hazards.sample.geojson"
# 판정 엔진 영역 중 이 단계 이상만 피한다 (사용자 결정 2026-10-02: 침수 "주의"부터)
MIN_LEVEL = "advisory"
DEFAULT_RISK_API_URL = "http://api:8000"
# 판정 엔진은 몇 분마다 돈다. 경로 요청마다 api를 부르지 않도록 이 시간 동안 재사용한다
CACHE_S = 60.0


@dataclass(frozen=True)
class Hazard:
    id: str                  # 예: flood-001, manhole-003. 응답의 avoided·still_inside에 그대로 나간다
    kind: HazardKind
    geometry: BaseGeometry   # 다각형, [lon, lat] 좌표
    grade: str | None = None
    source: str = "mock"
    name: str | None = None  # 사람이 읽는 이름 (예: "침수 경보"). 앱이 avoided id를 이름으로 바꿀 때 쓴다


class HazardSource(Protocol):
    def hazards(self) -> list[Hazard]: ...


def to_geojson(hazards: list[Hazard]) -> dict[str, Any]:
    """/api/route/hazards 응답: 지금 피하는 구역 (properties: id, kind, grade, name, source)"""
    return {"type": "FeatureCollection", "features": [
        {"type": "Feature", "geometry": mapping(h.geometry),
         "properties": {"id": h.id, "kind": h.kind, "grade": h.grade, "name": h.name or h.id, "source": h.source}}
        for h in hazards]}


class GeoJsonHazardSource:
    """GeoJSON 파일. 요청마다 다시 읽어서 파일을 고치면 재시작 없이 바로 반영된다 (파일이 작아 부담 없음)."""

    def __init__(self, path: str | Path | None = None):
        # 인자 > ROUTE_HAZARDS_FILE 환경 변수 > route/data/hazards.sample.geojson
        self.path = Path(path or os.environ.get("ROUTE_HAZARDS_FILE") or SAMPLE_FILE)

    def raw(self) -> dict[str, Any]:
        return to_geojson(self.hazards())

    def hazards(self) -> list[Hazard]:
        features = json.loads(self.path.read_text(encoding="utf-8"))["features"]
        return [_to_hazard(f) for f in features if f["properties"]["kind"] in AVOID_KINDS]


def _to_hazard(feature: dict[str, Any]) -> Hazard:
    p = feature["properties"]
    return Hazard(id=p["id"], kind=p["kind"], geometry=shape(feature["geometry"]), grade=p.get("grade"),
                  source=p.get("source", "mock"), name=p.get("name"))


class RiskAreaHazardSource:
    """A의 위험 판정 엔진 영역 (api `GET /api/v1/risk/areas?min_level=advisory`), 침수·산사태만.

    CACHE_S 동안 재사용한다. api에 못 닿으면 마지막으로 받은 값을 쓰고(`ok`는 그대로), 한 번도 못 받았으면
    빈 목록 + `ok=False` → 경로 응답의 hazards_ok=False (앱·AI가 "위험 정보를 확인하지 못했다"고 알린다).
    """

    def __init__(self, base_url: str | None = None, client: httpx.Client | None = None, cache_s: float = CACHE_S,
                 path: str = "/api/v1/risk/areas"):
        self.http = client or httpx.Client(base_url=base_url or os.environ.get("ROUTE_RISK_API_URL") or DEFAULT_RISK_API_URL,
                                           timeout=3.0)
        self.cache_s = cache_s
        self.path = path        # 시연 모드: DEMO_AREAS_PATH (실제 센서 위치 + 시연 측정값으로 같은 규칙 판정, api risk/demo.py)
        self._cached: list[Hazard] | None = None
        self._at = 0.0
        self.ok = True

    def hazards(self) -> list[Hazard]:
        if self._cached is not None and time.monotonic() - self._at < self.cache_s:
            return self._cached
        try:
            res = self.http.get(self.path, params={"min_level": MIN_LEVEL})
            res.raise_for_status()
            features = res.json()["features"]
        except (httpx.HTTPError, ValueError, KeyError) as e:
            log.warning("위험 영역을 못 읽음 (%s) → %s", type(e).__name__,
                        "마지막 값 사용" if self._cached is not None else "회피 없이 경로 계산")
            self.ok = self._cached is not None
            return self._cached or []
        self._cached = [
            Hazard(id=f"{f['properties']['hazard']}-{f.get('id')}", kind=f["properties"]["hazard"],
                   geometry=shape(f["geometry"]), grade=f["properties"].get("level"), source="risk_engine",
                   name=f["properties"].get("label"))
            for f in features if f["properties"].get("hazard") in AVOID_KINDS]
        self._at, self.ok = time.monotonic(), True
        return self._cached

    def raw(self) -> dict[str, Any]:
        return to_geojson(self.hazards())


DEMO_AREAS_PATH = "/api/v1/demo/risk/areas"


def default_source() -> HazardSource:
    """ROUTE_HAZARDS_FILE이 있으면 그 파일, 없으면 판정 엔진 영역"""
    return GeoJsonHazardSource() if os.environ.get("ROUTE_HAZARDS_FILE") else RiskAreaHazardSource()


def circle(lat: float, lon: float, radius_m: float, sides: int = 8) -> Polygon:
    """좌표 주변 반경 radius_m의 다각형. 수 m 규모라 위도에 따른 경도 길이 보정만 한다."""
    dlat = radius_m / 111_320
    dlon = radius_m / (111_320 * math.cos(math.radians(lat)))
    return Polygon([(lon + dlon * math.cos(a), lat + dlat * math.sin(a))
                    for a in (2 * math.pi * i / sides for i in range(sides))])
