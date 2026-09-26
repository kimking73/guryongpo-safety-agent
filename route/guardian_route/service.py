"""경로 안내: 요청 형식, 사용자 유형별 규칙, 위험 구역 회피, 이동 중 재계산 판단.

응답 키는 AI tool `request_route`(ai/guardian_ai/tools.py)와 같은 계약이다 (ai/docs/agent-design.md 5절).
B6: 도보 경로 + 침수·산사태 구역·맨홀 회피. B7: profile별 경사·계단 규칙(profiles.py), /api/route/check.
"""

from __future__ import annotations

import math
import re
from typing import Any, Literal

from pydantic import BaseModel, Field
from shapely.geometry import LineString, Point, mapping
from shapely.geometry.base import BaseGeometry
from shapely.ops import substring, transform

from . import polyline
from .gh import GraphHopperClient
from .hazards import GeoJsonHazardSource, Hazard, HazardSource
from .profiles import PROFILE_RULES

Profile = Literal["adult", "elderly", "wheelchair"]
CheckReason = Literal["off_route", "hazard_on_route"]

# 위험 구역 안 도로의 우선순위 배수. 0이면 그 길을 완전히 막아 출발지·도착지가 구역 안일 때 경로가 아예 없어진다.
# 0.001이면 1000배 비싼 길이 되어 다른 길이 있으면 반드시 돌아가고, 없을 때만 최소한으로 지난다 (still_inside로 알린다).
# 사용자 유형 규칙의 가장 강한 벌점(휠체어 급경사 ×0.05)보다 훨씬 세야 "급경사를 피하려다 위험 구역을 지나는" 일이 없다.
AVOID_PRIORITY = 0.001
# 이동 중 확인: 경로에서 이만큼 벗어나면 다시 계산한다. GPS 오차(보통 5~20m)보다 크게 둔다.
OFF_ROUTE_M = 30.0
# 도착지에서 이 거리 안이면 도착으로 본다.
ARRIVED_M = 20.0


class LatLon(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)


class RouteRequest(BaseModel):
    origin: LatLon
    destination: LatLon
    profile: Profile = "adult"      # adult(최단 시간), elderly·wheelchair(경사·계단 회피, 느린 속도)
    # 맨홀은 침수 때 뚜껑이 열려 위험하다. 침수 판정(A3·Risk engine)과 연결되기 전까지는 요청으로 켜고 끈다.
    avoid_manholes: bool = True


class RouteResponse(BaseModel):
    profile: Profile
    distance_m: int
    duration_s: int
    ascend_m: int = 0                                       # 오르막 합계
    descend_m: int = 0                                      # 내리막 합계
    max_slope_pct: int = 0                                  # 지나는 구간 중 가장 급한 경사 (오르막·내리막 절댓값)
    avoided: list[str] = Field(default_factory=list)       # 회피 없이 가면 지났을 위험 구역 중 이 경로가 피한 것
    still_inside: list[str] = Field(default_factory=list)  # 다른 길이 없어 이 경로도 지나는 위험 구역 (경고용)
    geometry: str                                           # 인코딩된 polyline (Google 형식, 정밀도 1e5, lat·lon 순)
    source: str = "graphhopper"


class RouteCheckRequest(BaseModel):
    """이동 중 앱이 주기적으로(예: 30초) 보낸다. 지금 따라가는 경로(geometry)와 현재 위치를 함께 보낸다."""
    current: LatLon
    destination: LatLon
    geometry: str                   # 지금 안내 중인 경로 (직전 /api/route 응답의 geometry)
    profile: Profile = "adult"
    avoid_manholes: bool = True


class RouteCheckResponse(BaseModel):
    reroute: bool                                           # True면 route로 경로를 바꾼다
    reasons: list[CheckReason] = Field(default_factory=list)
    off_route_m: int                                        # 현재 위치와 경로 사이 거리
    hazards_ahead: list[str] = Field(default_factory=list)  # 남은 경로에 걸친 위험 구역
    arrived: bool = False
    route: RouteResponse | None = None                      # reroute일 때 현재 위치에서 다시 계산한 경로


class RouteService:
    def __init__(self, client: GraphHopperClient | None = None, hazards: HazardSource | None = None):
        self.gh = client or GraphHopperClient()
        self.hazards = hazards or GeoJsonHazardSource()

    def route(self, req: RouteRequest) -> RouteResponse:
        """사용자 유형 규칙 + 위험 구역 회피 경로. GraphHopperUnavailable, RouteNotFound는 api.py가 HTTP 오류로 바꾼다.

        위험 구역이 있으면 GraphHopper를 두 번 부른다: 회피 경로(응답으로 나감)와, 같은 유형 규칙에서
        위험 구역만 뺀 기본 경로(avoided 계산용).
        """
        points = [(req.origin.lat, req.origin.lon), (req.destination.lat, req.destination.lon)]
        zones = self._zones(req.avoid_manholes)
        rules = PROFILE_RULES[req.profile]

        safe = self.gh.route(points, custom_model=build_model(rules, zones))
        avoided: list[str] = []
        still_inside: list[str] = []
        if zones:
            base = self.gh.route(points, custom_model=build_model(rules, []))
            safe_line, base_line = _line(safe["points"]), _line(base["points"])
            still_inside = [z.id for z in zones if safe_line.intersects(z.geometry)]
            avoided = [z.id for z in zones if base_line.intersects(z.geometry) and z.id not in still_inside]

        return RouteResponse(
            profile=req.profile,
            distance_m=round(safe["distance"]),
            duration_s=round(safe["time"] / 1000),     # GraphHopper time은 밀리초
            ascend_m=round(safe.get("ascend") or 0),
            descend_m=round(safe.get("descend") or 0),
            max_slope_pct=_max_slope(safe),
            avoided=avoided,
            still_inside=still_inside,
            geometry=safe["points"],
        )

    def check(self, req: RouteCheckRequest) -> RouteCheckResponse:
        """이동 중 재계산이 필요한지 판단한다. 필요하면 현재 위치에서 새 경로를 계산해 함께 돌려준다.

        재계산 사유: 경로에서 OFF_ROUTE_M 넘게 벗어남(off_route), 남은 경로에 위험 구역이 걸침(hazard_on_route, 예:
        이동 중 새 침수 구역이 생김). 다른 길이 없어 원래부터 지나던 구역이면 새 경로도 똑같으므로 재계산하지 않고
        hazards_ahead로 경고만 한다.
        """
        here = (req.current.lon, req.current.lat)
        to_m = _meters_projector(req.current.lat)
        pos = transform(to_m, Point(here))
        line = transform(to_m, _line(req.geometry))

        if pos.distance(transform(to_m, Point(req.destination.lon, req.destination.lat))) <= ARRIVED_M:
            return RouteCheckResponse(reroute=False, off_route_m=round(pos.distance(line)), arrived=True)

        off_m = pos.distance(line)
        # 남은 경로: 현재 위치에서 가장 가까운 경로 지점부터 끝까지
        ahead = substring(line, line.project(pos), line.length) if line.length > 0 else line
        hazards_ahead = [z.id for z in self._zones(req.avoid_manholes)
                         if ahead.intersects(transform(to_m, z.geometry))]

        reasons: list[CheckReason] = []
        if off_m > OFF_ROUTE_M:
            reasons.append("off_route")
        new_route = None
        if reasons or hazards_ahead:
            new_route = self.route(RouteRequest(origin=req.current, destination=req.destination,
                                                profile=req.profile, avoid_manholes=req.avoid_manholes))
            # 새 경로가 피할 수 있는 구역이 있을 때만 위험 사유로 재계산한다 (없으면 같은 경로를 계속 주게 된다)
            if set(hazards_ahead) - set(new_route.still_inside):
                reasons.append("hazard_on_route")
        return RouteCheckResponse(
            reroute=bool(reasons), reasons=reasons, off_route_m=round(off_m),
            hazards_ahead=hazards_ahead, route=new_route if reasons else None,
        )

    def health(self) -> dict:
        return {"status": "ok", "graphhopper": "ok" if self.gh.ping() else "error"}

    def _zones(self, avoid_manholes: bool) -> list[Hazard]:
        return [h for h in self.hazards.hazards() if h.kind != "manhole" or avoid_manholes]


def build_model(rules: dict[str, list[dict[str, Any]]], zones: list[Hazard]) -> dict[str, Any] | None:
    """GraphHopper custom_model: 사용자 유형 규칙 + 위험 구역 회피. 더할 게 없으면 None (기본 도보 모델)."""
    priority = list(rules.get("priority", []))
    speed = list(rules.get("speed", []))
    model: dict[str, Any] = {}
    if zones:
        # 구역마다 area를 만들고 그 안의 길 우선순위를 AVOID_PRIORITY배로 낮춘다
        priority += [{"if": f"in_{area_id(z.id)}", "multiply_by": str(AVOID_PRIORITY)} for z in zones]
        model["areas"] = {"type": "FeatureCollection", "features": [
            {"type": "Feature", "id": area_id(z.id), "properties": {}, "geometry": mapping(z.geometry)}
            for z in zones]}
    if priority:
        model["priority"] = priority
    if speed:
        model["speed"] = speed
    return model or None


def avoid_model(zones: list[Hazard]) -> dict[str, Any] | None:
    """위험 구역 회피 규칙만 (성인 기준). 지도 화면(/maps/)에 붙여 넣어 확인할 때 쓴다."""
    return build_model(PROFILE_RULES["adult"], zones)


def area_id(hazard_id: str) -> str:
    """GraphHopper area 이름은 영문·숫자·밑줄만 된다 (in_<이름>으로 쓰기 때문). flood-001 → flood_001"""
    return re.sub(r"\W", "_", hazard_id)


def _line(encoded: str) -> BaseGeometry:
    """인코딩된 polyline → shapely 선 ([lon, lat] 좌표). 점이 하나뿐이면(출발=도착) 점."""
    coords = [(lon, lat) for lat, lon in polyline.decode(encoded)]
    return LineString(coords) if len(coords) > 1 else Point(coords[0])


def _max_slope(path: dict[str, Any]) -> int:
    """GraphHopper details.average_slope ([시작, 끝, 경사%] 목록)에서 가장 급한 값."""
    slopes = [abs(d[2]) for d in (path.get("details") or {}).get("average_slope", []) if d[2] is not None]
    return round(max(slopes)) if slopes else 0


def _meters_projector(lat0: float):
    """[lon, lat] → 대략적인 m 좌표. 구룡포처럼 좁은 범위의 거리 계산용 (수 km 안에서 오차 1% 미만)."""
    kx = 111_320 * math.cos(math.radians(lat0))
    ky = 110_540

    def to_m(x, y, z=None):
        return x * kx, y * ky
    return to_m
