"""경로에서 피할 위험 구역 (침수·산사태 구역, 맨홀).

지금은 임시 GeoJSON 파일(route/data/hazards.sample.geojson)에서 읽는다.
A7이 hazard_zones·facilities 테이블을 적재하면 같은 모양의 PostGIS 읽기 클래스를 만들어 RouteService에 넣는다.
좌표는 GeoJSON 규칙대로 [lon, lat].
"""

from __future__ import annotations

import json
import math
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal, Protocol

from shapely.geometry import Polygon, shape
from shapely.geometry.base import BaseGeometry

HazardKind = Literal["flood", "landslide", "manhole"]

DEFAULT_FILE = Path(__file__).resolve().parent.parent / "data" / "hazards.sample.geojson"
# 맨홀은 점이라 이 반경의 작은 다각형으로 바꿔 그 위를 지나는 길을 피한다.
MANHOLE_RADIUS_M = 5.0


@dataclass(frozen=True)
class Hazard:
    id: str                  # 예: flood-001, manhole-003. 응답의 avoided·still_inside에 그대로 나간다
    kind: HazardKind
    geometry: BaseGeometry   # 다각형, [lon, lat] 좌표
    grade: str | None = None
    source: str = "mock"


class HazardSource(Protocol):
    def hazards(self) -> list[Hazard]: ...


class GeoJsonHazardSource:
    """GeoJSON 파일. 요청마다 다시 읽어서 파일을 고치면 재시작 없이 바로 반영된다 (파일이 작아 부담 없음)."""

    def __init__(self, path: str | Path | None = None):
        # 인자 > ROUTE_HAZARDS_FILE 환경 변수 > route/data/hazards.sample.geojson
        self.path = Path(path or os.environ.get("ROUTE_HAZARDS_FILE") or DEFAULT_FILE)

    def raw(self) -> dict[str, Any]:
        return json.loads(self.path.read_text(encoding="utf-8"))

    def hazards(self) -> list[Hazard]:
        return [_to_hazard(f) for f in self.raw()["features"]]


def _to_hazard(feature: dict[str, Any]) -> Hazard:
    p = feature["properties"]
    geom = shape(feature["geometry"])
    if p["kind"] == "manhole":
        geom = circle(geom.y, geom.x, MANHOLE_RADIUS_M)
    return Hazard(id=p["id"], kind=p["kind"], geometry=geom, grade=p.get("grade"), source=p.get("source", "mock"))


def circle(lat: float, lon: float, radius_m: float, sides: int = 8) -> Polygon:
    """좌표 주변 반경 radius_m의 다각형. 수 m 규모라 위도에 따른 경도 길이 보정만 한다."""
    dlat = radius_m / 111_320
    dlon = radius_m / (111_320 * math.cos(math.radians(lat)))
    return Polygon([(lon + dlon * math.cos(a), lat + dlat * math.sin(a))
                    for a in (2 * math.pi * i / sides for i in range(sides))])
