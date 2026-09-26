"""경로 안내: 요청 형식, 위험 구역 회피, GraphHopper 호출, 응답 형식.

응답 키는 AI tool `request_route`(ai/guardian_ai/tools.py)와 같은 계약이다 (ai/docs/agent-design.md 5절).
B6: 도보 경로 + 침수·산사태 구역·맨홀 회피. profile별 가중치(오르막 등)는 B7.
"""

from __future__ import annotations

import re
from typing import Any, Literal

from pydantic import BaseModel, Field
from shapely.geometry import LineString, Point, mapping
from shapely.geometry.base import BaseGeometry

from . import polyline
from .gh import GraphHopperClient
from .hazards import GeoJsonHazardSource, Hazard, HazardSource

Profile = Literal["adult", "elderly", "wheelchair"]

# 위험 구역 안 도로의 우선순위 배수. 0이면 그 길을 완전히 막아 출발지·도착지가 구역 안일 때 경로가 아예 없어진다.
# 0.01이면 100배 비싼 길이 되어 다른 길이 있으면 반드시 돌아가고, 없을 때만 최소한으로 지난다 (still_inside로 알린다).
AVOID_PRIORITY = 0.01


class LatLon(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)


class RouteRequest(BaseModel):
    origin: LatLon
    destination: LatLon
    profile: Profile = "adult"      # 지금은 받기만 하고 모두 같은 도보 경로 (B7에서 분기)
    # 맨홀은 침수 때 뚜껑이 열려 위험하다. 침수 판정(A3·Risk engine)과 연결되기 전까지는 요청으로 켜고 끈다.
    avoid_manholes: bool = True


class RouteResponse(BaseModel):
    profile: Profile
    distance_m: int
    duration_s: int
    avoided: list[str] = Field(default_factory=list)       # 회피 없이 가면 지났을 위험 구역 중 이 경로가 피한 것
    still_inside: list[str] = Field(default_factory=list)  # 다른 길이 없어 이 경로도 지나는 위험 구역 (경고용)
    geometry: str                                           # 인코딩된 polyline (Google 형식, 정밀도 1e5, lat·lon 순)
    source: str = "graphhopper"


class RouteService:
    def __init__(self, client: GraphHopperClient | None = None, hazards: HazardSource | None = None):
        self.gh = client or GraphHopperClient()
        self.hazards = hazards or GeoJsonHazardSource()

    def route(self, req: RouteRequest) -> RouteResponse:
        """위험 구역을 피한 경로를 계산한다. GraphHopperUnavailable, RouteNotFound 예외는 api.py가 HTTP 오류로 바꾼다.

        GraphHopper를 두 번 부른다: 위험 구역을 피한 경로(응답으로 나감)와, 피하지 않은 기본 경로(avoided 계산용).
        """
        points = [(req.origin.lat, req.origin.lon), (req.destination.lat, req.destination.lon)]
        zones = [h for h in self.hazards.hazards() if h.kind != "manhole" or req.avoid_manholes]

        safe = self.gh.route(points, custom_model=avoid_model(zones) if zones else None)
        avoided: list[str] = []
        still_inside: list[str] = []
        if zones:
            base = self.gh.route(points)
            safe_line, base_line = _line(safe["points"]), _line(base["points"])
            still_inside = [z.id for z in zones if safe_line.intersects(z.geometry)]
            avoided = [z.id for z in zones if base_line.intersects(z.geometry) and z.id not in still_inside]

        return RouteResponse(
            profile=req.profile,
            distance_m=round(safe["distance"]),
            duration_s=round(safe["time"] / 1000),     # GraphHopper time은 밀리초
            avoided=avoided,
            still_inside=still_inside,
            geometry=safe["points"],
        )

    def health(self) -> dict:
        return {"status": "ok", "graphhopper": "ok" if self.gh.ping() else "error"}


def avoid_model(zones: list[Hazard]) -> dict[str, Any]:
    """GraphHopper custom_model: 구역마다 area를 만들고 그 안의 길 우선순위를 AVOID_PRIORITY배로 낮춘다."""
    features = [{"type": "Feature", "id": area_id(z.id), "properties": {}, "geometry": mapping(z.geometry)}
                for z in zones]
    return {
        "priority": [{"if": f"in_{area_id(z.id)}", "multiply_by": str(AVOID_PRIORITY)} for z in zones],
        "areas": {"type": "FeatureCollection", "features": features},
    }


def area_id(hazard_id: str) -> str:
    """GraphHopper area 이름은 영문·숫자·밑줄만 된다 (in_<이름>으로 쓰기 때문). flood-001 → flood_001"""
    return re.sub(r"\W", "_", hazard_id)


def _line(encoded: str) -> BaseGeometry:
    """인코딩된 polyline → shapely 선 ([lon, lat] 좌표). 점이 하나뿐이면(출발=도착) 점."""
    coords = [(lon, lat) for lat, lon in polyline.decode(encoded)]
    return LineString(coords) if len(coords) > 1 else Point(coords[0])
