"""경로 안내: 요청 형식, 사용자 유형별 규칙, 위험 구역 회피, 이동 중 재계산 판단.

응답 키는 AI tool `request_route`(ai/guardian_ai/tools.py)와 같은 계약이다 (ai/docs/agent-design.md 5절).
B6: 도보 경로 + 침수·산사태 구역 회피 (판정 엔진 영역, hazards.py). B7: 노약자 경사·계단 규칙(profiles.py), /api/route/check.
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
from .gh import GraphHopperClient, GraphHopperUnavailable, RouteNotFound
from .hazards import DEMO_AREAS_PATH, Hazard, HazardSource, RiskAreaHazardSource, default_source
from .profiles import PROFILE_RULES, rules_for
from .sea import ALTERNATIVES, ApiShelterSource, SeaChart, ShelterSource, bearing_label, pick_shelter

Profile = Literal["adult", "elderly"]
Strategy = Literal["shortest", "safest", "flat", "fastest"]   # fastest = 예전 이름, safest와 같음
Mode = Literal["walk", "car"]     # 이동 수단 (2026-10-07 자동차 추가) → GraphHopper 프로필 foot·car
GH_PROFILE = {"walk": "foot", "car": "car"}
CheckReason = Literal["off_route", "hazard_on_route"]

# 위험 구역 안 도로의 우선순위 배수. 0이면 그 길을 완전히 막아 출발지·도착지가 구역 안일 때 경로가 아예 없어진다.
# 0.001이면 1000배 비싼 길이 되어 다른 길이 있으면 반드시 돌아가고, 없을 때만 최소한으로 지난다 (still_inside로 알린다).
# 사용자 유형 규칙의 가장 강한 벌점(노약자 급경사 ×0.2)보다 훨씬 세야 "급경사를 피하려다 위험 구역을 지나는" 일이 없다.
AVOID_PRIORITY = 0.001
# GraphHopper가 구역을 가로지르는 일부 도로를 구역 안으로 보지 못한다 (2026-10-02 확인: 긴 도로 구간이 작은 구역을
# 꼭짓점 없이 가로지를 때, 구역을 80m 넓혀야 잡힘). 그래서 받은 경로를 직접 검사해 피할 수 있는 구역을 지나면
# 그 구역만 이만큼(m) 넓혀 다시 요청한다. 출발지·도착지(또는 GraphHopper가 붙인 가장 가까운 도로 위 점)가
# 들어 있는 구역은 빠져나가거나 들어가야 하니 넓히지 않는다.
WIDEN_STEPS_M = (50.0, 100.0)
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
    strategy: Strategy | None = None  # 앱의 경로 선택: shortest(가까운 = 위험 회피 없는 최단) · safest(안전 = 위험 회피, 기본) · flat(오르막 회피) — profiles.rules_for
    profile: Profile = "adult"      # adult(최단 시간, 경사 무시), elderly(급경사 회피·같은 경사면 계단 선호, 느린 속도)
    mode: Mode = "walk"             # walk(도보, 기본) · car(자동차 — 차로·회전 제한, 위험 구역 회피는 같다. 사용자 유형은 안 씀)
    demo: bool = False              # 앱 시연 모드: 실제 위험 영역 대신 시연 위험 영역(api /demo/risk/areas)을 피한다


class RouteResponse(BaseModel):
    strategy: Strategy | None = None
    mode: Mode = "walk"
    profile: Profile                                        # 요청한 사용자 유형 그대로 (걸음 속도 기준)
    distance_m: int
    duration_s: int
    ascend_m: int = 0                                       # 오르막 합계
    descend_m: int = 0                                      # 내리막 합계
    max_slope_pct: int = 0                                  # 지나는 구간 중 가장 급한 경사 (오르막·내리막 절댓값)
    max_uphill_pct: int = 0                                 # 진행 방향 기준 가장 급한 오르막 (오르막 회피 경로 비교용)
    avoided: list[str] = Field(default_factory=list)       # 회피 없이 가면 지났을 위험 구역 중 이 경로가 피한 것
    still_inside: list[str] = Field(default_factory=list)  # 다른 길이 없어 이 경로도 지나는 위험 구역 (경고용)
    geometry: str                                           # 인코딩된 polyline (Google 형식, 정밀도 1e5, lat·lon 순)
    source: str = "graphhopper"
    hazards_ok: bool = True                                 # False면 위험 영역을 못 읽어 회피 없이 계산한 경로


class RouteCheckRequest(BaseModel):
    """이동 중 앱이 주기적으로(예: 30초) 보낸다. 지금 따라가는 경로(geometry)와 현재 위치를 함께 보낸다."""
    current: LatLon
    destination: LatLon
    geometry: str                   # 지금 안내 중인 경로 (직전 /api/route 응답의 geometry)
    profile: Profile = "adult"
    strategy: Strategy | None = None  # 직전 /api/route 요청과 같은 값 — 다시 계산해도 같은 종류의 길
    mode: Mode = "walk"
    demo: bool = False


class RouteCheckResponse(BaseModel):
    reroute: bool                                           # True면 route로 경로를 바꾼다
    reasons: list[CheckReason] = Field(default_factory=list)
    off_route_m: int                                        # 현재 위치와 경로 사이 거리
    hazards_ahead: list[str] = Field(default_factory=list)  # 남은 경로에 걸친 위험 구역
    arrived: bool = False
    route: RouteResponse | None = None                      # reroute일 때 현재 위치에서 다시 계산한 경로


class SeaRouteRequest(BaseModel):
    """B11: 바다 위(배)에서 대피. destination을 생략하면 항구에서 가장 가까운 갈 만한 대피소로 간다."""
    origin: LatLon
    destination: LatLon | None = None
    profile: Profile = "adult"
    demo: bool = False


class SeaPort(BaseModel):
    id: str
    name: str
    kind: str
    berth: LatLon                   # 배를 댈 곳 (해상 구간 도착점)
    land_point: LatLon              # 도로와 이어지는 곳 (육상 경로 출발점)


class SeaAlternative(BaseModel):
    id: str
    name: str
    distance_m: int
    bearing_deg: float
    bearing_label: str


class SeaLeg(BaseModel):
    distance_m: int                                         # 바닷길 길이 (육지·방파제를 돌아감)
    straight_m: int                                         # 출발 좌표 → 접안점 직선 거리
    bearing_deg: float                                      # 접안점의 진북 기준 방위 (0~360, 직선)
    bearing_label: str                                      # 16방위 한글 (예: 북서쪽)
    direct: bool = True                                     # False면 곶·방파제를 돌아 들어가야 함 (path가 꺾임)
    path: str                                               # 바닷길 꺾은선 (인코딩 polyline, geometry와 같은 형식) 출발 → 접안점
    path_found: bool = True                                 # False면 바닷길을 못 찾음 — path는 출발점 하나(선 없음), 방위만 참고
    alternatives: list[SeaAlternative] = Field(default_factory=list)  # 다음으로 가까운 항구 (직선 항로가 열린 곳 우선)


class SeaDestination(BaseModel):
    name: str | None = None                                 # 자동 선택한 대피소 이름 (목적지를 직접 주면 None)
    lat: float
    lon: float
    note: str | None = None                                 # 갈 만한 대피소가 없을 때 경고


class SeaRouteResponse(BaseModel):
    at_sea: bool                                            # 출발 좌표가 해상인지 (OSM 해안선, 물가 30m는 육지로 봄)
    port: SeaPort | None = None
    sea_leg: SeaLeg | None = None
    destination: SeaDestination | None = None
    land_route: RouteResponse | None = None                 # 육지 출발이면 출발지부터, 해상이면 land_point부터
    land_route_error: str | None = None                     # 육상 경로를 못 구한 이유 (해상 안내는 그대로 준다)


class RouteService:
    def __init__(self, client: GraphHopperClient | None = None, hazards: HazardSource | None = None,
                 chart: SeaChart | None = None, shelters: ShelterSource | None = None,
                 demo_hazards: HazardSource | None = None):
        self.gh = client or GraphHopperClient()
        self.hazards = hazards or default_source()
        self._demo_hazards = demo_hazards
        self._chart = chart
        self.shelters = shelters or ApiShelterSource()

    @property
    def chart(self) -> SeaChart:
        """육지·항구 파일은 해상 경로를 처음 부를 때 읽는다 (일반 경로만 쓰는 테스트는 파일이 필요 없게)."""
        if self._chart is None:
            self._chart = SeaChart.from_files()
        return self._chart

    def sea(self, req: SeaRouteRequest) -> SeaRouteResponse:
        """해상이면 최근접 항(직선 항로가 열린 곳 우선)까지 거리·방위 + 항구 육상 지점부터 경로.
        육지면 at_sea=False + 일반 경로. OutsideArea(범위 밖)는 api.py가 422로 바꾼다.
        GraphHopper 장애·경로 없음은 해상 안내를 살리고 land_route_error로 알린다."""
        o = (req.origin.lat, req.origin.lon)
        at_sea = self.chart.is_at_sea(*o)
        port = sea_leg = None
        start = o
        if at_sea:
            ranked = self.chart.rank_ports(*o)
            best = ranked[0]
            p = best.port
            port = SeaPort(id=p.id, name=p.name, kind=p.kind, berth=LatLon(lat=p.berth[0], lon=p.berth[1]),
                           land_point=LatLon(lat=p.land_point[0], lon=p.land_point[1]))
            alts = [c for c in ranked[1:] if c.reachable][:ALTERNATIVES]
            sea_leg = SeaLeg(distance_m=round(best.distance_m), straight_m=round(best.straight_m),
                             bearing_deg=round(best.bearing_deg, 1), bearing_label=bearing_label(best.bearing_deg),
                             direct=best.direct, path=polyline.encode(list(best.path)), path_found=best.reachable,
                             alternatives=[SeaAlternative(id=c.port.id, name=c.port.name, distance_m=round(c.distance_m),
                                                          bearing_deg=round(c.bearing_deg, 1),
                                                          bearing_label=bearing_label(c.bearing_deg)) for c in alts])
            start = p.land_point

        if req.destination is not None:
            dest = SeaDestination(lat=req.destination.lat, lon=req.destination.lon)
        else:
            shelter, note = pick_shelter(start, self.shelters.shelters(), self._zones(req.demo))
            if shelter is None:
                return SeaRouteResponse(at_sea=at_sea, port=port, sea_leg=sea_leg, land_route_error=note)
            dest = SeaDestination(name=shelter.name, lat=shelter.lat, lon=shelter.lon, note=note)

        try:
            land = self.route(RouteRequest(origin=LatLon(lat=start[0], lon=start[1]),
                                           destination=LatLon(lat=dest.lat, lon=dest.lon), profile=req.profile, demo=req.demo))
        except (GraphHopperUnavailable, RouteNotFound) as e:
            if not at_sea:
                raise   # 육지 출발이면 일반 경로와 같은 오류 (503/404)
            return SeaRouteResponse(at_sea=True, port=port, sea_leg=sea_leg, destination=dest,
                                    land_route_error=f"항구에서 대피소까지 경로를 구하지 못했습니다 ({e})")
        return SeaRouteResponse(at_sea=at_sea, port=port, sea_leg=sea_leg, destination=dest, land_route=land)

    def route(self, req: RouteRequest) -> RouteResponse:
        """사용자 유형 규칙 + 위험 구역 회피 경로. GraphHopperUnavailable, RouteNotFound는 api.py가 HTTP 오류로 바꾼다.

        위험 구역이 있으면 GraphHopper를 두 번 부른다: 회피 경로(응답으로 나감)와, 같은 유형 규칙에서
        위험 구역만 뺀 기본 경로(avoided 계산용).
        """
        points = [(req.origin.lat, req.origin.lon), (req.destination.lat, req.destination.lon)]
        zones = self._zones(req.demo)
        # 가까운 경로(shortest)만 위험 구역을 피하지 않는다 — 지나는 구역은 still_inside로 알린다. 나머지는 규칙만 다르다 (profiles.rules_for)
        rules = rules_for(req.profile, req.strategy, req.mode)
        avoid = req.strategy != "shortest"
        gh_profile = GH_PROFILE[req.mode]

        safe = self.gh.route(points, profile=gh_profile, custom_model=build_model(rules, zones if avoid else []))
        avoided: list[str] = []
        still_inside: list[str] = []
        if zones and not avoid:
            still_inside = [z.id for z in zones if _line(safe["points"]).intersects(z.geometry)]
        elif zones:
            safe = self._widen_until_clear(points, rules, zones, safe, gh_profile)
            base = self.gh.route(points, profile=gh_profile, custom_model=build_model(rules, []))
            safe_line, base_line = _line(safe["points"]), _line(base["points"])
            still_inside = [z.id for z in zones if safe_line.intersects(z.geometry)]
            avoided = [z.id for z in zones if base_line.intersects(z.geometry) and z.id not in still_inside]

        return RouteResponse(
            strategy=req.strategy,
            mode=req.mode,
            profile=req.profile,
            distance_m=round(safe["distance"]),
            duration_s=round(safe["time"] / 1000),     # GraphHopper time은 밀리초
            ascend_m=round(safe.get("ascend") or 0),
            descend_m=round(safe.get("descend") or 0),
            max_slope_pct=_max_slope(safe),
            max_uphill_pct=_max_uphill(safe),
            avoided=avoided,
            still_inside=still_inside,
            geometry=safe["points"],
            hazards_ok=getattr(self.source(req.demo), "ok", True),
        )

    def _widen_until_clear(self, points, rules, zones: list[Hazard], path: dict[str, Any],
                           gh_profile: str = "foot") -> dict[str, Any]:
        """경로가 피할 수 있는 구역을 지나면 그 구역을 넓혀 다시 요청한다 (WIDEN_STEPS_M 설명). 못 피하면 처음 경로."""
        # 요청 좌표 + GraphHopper가 붙인 도로 위 시작·끝점 (좌표는 구역 밖이어도 가장 가까운 길이 구역 안일 수 있다)
        snapped = polyline.decode(path["points"])
        ends = [Point(lon, lat) for lat, lon in [*points, snapped[0], snapped[-1]]]
        avoidable = [z for z in zones if not any(z.geometry.intersects(p) for p in ends)]
        crossed = [z for z in avoidable if _line(path["points"]).intersects(z.geometry)]
        if not crossed:
            return path
        to_m = _meters_projector(points[0][0])
        to_deg = _degrees_projector(points[0][0])
        for widen_m in WIDEN_STEPS_M:
            wide = {z.id for z in crossed}
            widened = [Hazard(z.id, z.kind, transform(to_deg, transform(to_m, z.geometry).buffer(widen_m)), z.grade, z.source, z.name)
                       if z.id in wide else z for z in zones]
            retry = self.gh.route(points, profile=gh_profile, custom_model=build_model(rules, widened))
            if not any(_line(retry["points"]).intersects(z.geometry) for z in crossed):
                return retry
        return path

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
        hazards_ahead = [z.id for z in self._zones(req.demo)
                         if ahead.intersects(transform(to_m, z.geometry))]

        reasons: list[CheckReason] = []
        if off_m > OFF_ROUTE_M:
            reasons.append("off_route")
        new_route = None
        if reasons or hazards_ahead:
            new_route = self.route(RouteRequest(origin=req.current, destination=req.destination, profile=req.profile,
                                                strategy=req.strategy, mode=req.mode, demo=req.demo))
            # 새 경로가 피할 수 있는 구역이 있을 때만 위험 사유로 재계산한다 (없으면 같은 경로를 계속 주게 된다)
            if set(hazards_ahead) - set(new_route.still_inside):
                reasons.append("hazard_on_route")
        return RouteCheckResponse(
            reroute=bool(reasons), reasons=reasons, off_route_m=round(off_m),
            hazards_ahead=hazards_ahead, route=new_route if reasons else None,
        )

    def health(self) -> dict:
        return {"status": "ok", "graphhopper": "ok" if self.gh.ping() else "error"}

    def source(self, demo: bool = False) -> HazardSource:
        """피할 위험 영역 출처: 실측(판정 엔진) 또는 시연(실제 센서 위치 + 시연 측정값, api /demo/risk/areas)"""
        if not demo:
            return self.hazards
        if self._demo_hazards is None:
            self._demo_hazards = RiskAreaHazardSource(path=DEMO_AREAS_PATH)
        return self._demo_hazards

    def _zones(self, demo: bool = False) -> list[Hazard]:
        return self.source(demo).hazards()


def build_model(rules: dict[str, Any], zones: list[Hazard]) -> dict[str, Any] | None:
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
    if rules.get("distance_influence") is not None:
        model["distance_influence"] = rules["distance_influence"]
    return model or None


def avoid_model(zones: list[Hazard]) -> dict[str, Any] | None:
    """위험 구역 회피 규칙만 (성인 기준). 지도 화면(/maps/)에 붙여 넣어 확인할 때 쓴다."""
    return build_model(PROFILE_RULES["adult"], zones)


def area_id(hazard_id: str) -> str:
    """GraphHopper area 이름은 영문·숫자·밑줄만 되고 밑줄 두 개(__)도 거부한다 (in_<이름>으로 쓰기 때문).
    flood-001 → flood_001. 시연 위험 영역 id는 음수라 flood--3이 되는데, flood__3이 되면 경로 요청이 통째로 실패했다
    (2026-10-07 VM 시연 모드 길찾기 전부 실패) → 음수는 n으로: flood--3 → flood_n3"""
    return re.sub(r"_+", "_", re.sub(r"\W", "_", hazard_id.replace("--", "-n")))


def _line(encoded: str) -> BaseGeometry:
    """인코딩된 polyline → shapely 선 ([lon, lat] 좌표). 점이 하나뿐이면(출발=도착) 점."""
    coords = [(lon, lat) for lat, lon in polyline.decode(encoded)]
    return LineString(coords) if len(coords) > 1 else Point(coords[0])


def _max_slope(path: dict[str, Any]) -> int:
    """GraphHopper details.average_slope ([시작, 끝, 경사%] 목록)에서 가장 급한 값."""
    slopes = [abs(d[2]) for d in (path.get("details") or {}).get("average_slope", []) if d[2] is not None]
    return round(max(slopes)) if slopes else 0


def _max_uphill(path: dict[str, Any]) -> int:
    """진행 방향 기준 가장 급한 오르막 (average_slope 양수 중 최대, 없으면 0)."""
    ups = [d[2] for d in (path.get("details") or {}).get("average_slope", []) if d[2] is not None and d[2] > 0]
    return round(max(ups)) if ups else 0


def _meters_projector(lat0: float):
    """[lon, lat] → 대략적인 m 좌표. 구룡포처럼 좁은 범위의 거리 계산용 (수 km 안에서 오차 1% 미만)."""
    kx = 111_320 * math.cos(math.radians(lat0))
    ky = 110_540

    def to_m(x, y, z=None):
        return x * kx, y * ky
    return to_m


def _degrees_projector(lat0: float):
    """_meters_projector의 역변환 (m 좌표 → [lon, lat])."""
    kx = 111_320 * math.cos(math.radians(lat0))
    ky = 110_540

    def to_deg(x, y, z=None):
        return x / kx, y / ky
    return to_deg
