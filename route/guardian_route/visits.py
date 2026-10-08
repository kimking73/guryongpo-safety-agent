"""방재단 다중 방문 경로 (2026-10-09 사용자 요청): 출발점 → 고른 집 여러 곳을 모두 도는 길 (돌아오지 않음).

두 가지를 한 번에 계산한다.
- shortest: 고른 곳을 가장 짧게 도는 순서
- priority: B13 순위 단계(tier 1~6, 작을수록 먼저 — server/app/priority.py)를 지키고, 같은 단계 안에서는 가장 짧게
위험 구역은 무조건 피한다 (우선순위 0 = 통행 불가). 출발점·방문할 집이 들어 있는(또는 50m 안) 구역만 들어가야
도착할 수 있으니 AVOID_PRIORITY(0.001)로 꼭 필요할 때만 지난다. 그래도 길이 없는 구간은 막은 구역을 풀어 다시
계산하고 blocked_zones로 알린다.

GraphHopper 무료판에는 거리표(matrix) API가 없어 모든 방향 쌍을 경로로 계산한다 (최대 11×10 = 110번, 동시 8개).
순서는 Held-Karp DP로 정확한 최적 (10곳 = 2^10 × 10 × 10). 비용 = 거리(m). 같은 거리면 id 순서로 정해 결과가 늘 같다.
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from typing import TYPE_CHECKING, Any

from pydantic import BaseModel, Field
from shapely.geometry import Point
from shapely.ops import transform

from .gh import RouteNotFound
from .profiles import rules_for

if TYPE_CHECKING:
    from .hazards import Hazard
    from .service import RouteService

MAX_STOPS = 10
NEAR_M = 50.0          # 이 거리 안에 출발점·방문 집이 있는 구역은 막지 않는다 (가장 가까운 도로가 구역 안일 수 있다)
WORKERS = 8
UNREACHABLE = 10 ** 9   # 쌍 경로가 아예 없을 때의 비용


class LatLonIn(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)


class VisitStop(BaseModel):
    id: str = Field(min_length=1, max_length=64)      # 대상 id (개인정보 없이 id·좌표만 받는다)
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)
    tier: int = Field(default=4, ge=1, le=6)            # B13 priority_tier (1 도움요청+장애 … 6 대피 완료)


class VisitRequest(BaseModel):
    origin: LatLonIn
    stops: list[VisitStop] = Field(min_length=1, max_length=MAX_STOPS)
    mode: str = Field(default="walk", pattern="^(walk|car)$")
    profile: str = Field(default="adult", pattern="^(adult|elderly)$")
    demo: bool = False


class VisitLeg(BaseModel):
    id: str
    seq: int                 # 방문 순서 1부터
    tier: int
    leg_distance_m: int      # 직전 지점(출발점 또는 앞 집)에서 이 집까지
    leg_duration_s: int


class VisitPlan(BaseModel):
    order: list[VisitLeg]
    distance_m: int
    duration_s: int
    geometry: str            # 출발점 → 모든 집 (인코딩된 polyline, /api/route와 같은 형식)
    still_inside: list[str] = Field(default_factory=list)   # 다른 길이 없어 지나는 위험 구역


class VisitResponse(BaseModel):
    mode: str
    shortest: VisitPlan
    priority: VisitPlan
    blocked_zones: list[str] = Field(default_factory=list)  # 막아야 했지만 길이 없어 풀어 준 구역
    hazards_ok: bool = True


# ------------------------------------------------------------------ 순서 (순수 함수)
def solve(cost: list[list[float]], tiers: list[int], ids: list[str], by_priority: bool) -> list[int]:
    """cost[i][j]: 지점 i → j 비용 (0 = 출발점, 1..n = 집). 돌아오지 않는 경로의 방문 순서(집 번호 0..n-1)를 돌려준다.
    by_priority 면 더 높은 단계(작은 tier)가 남아 있는 동안 낮은 단계 집을 고르지 않는다."""
    n = len(tiers)
    full = (1 << n) - 1

    def allowed(j: int, mask: int) -> bool:
        if not by_priority:
            return True
        return all(mask >> k & 1 or k == j or tiers[k] >= tiers[j] for k in range(n))

    # best[mask][j] = (비용, 지나온 id 순서) — 같은 비용이면 id 순서가 작은 쪽 (결과가 늘 같게)
    best: list[list[tuple[float, tuple[str, ...]] | None]] = [[None] * n for _ in range(1 << n)]
    for j in range(n):
        if allowed(j, 0):
            best[1 << j][j] = (cost[0][j + 1], (ids[j],))
    for mask in range(1, full + 1):
        for j in range(n):
            cur = best[mask][j]
            if cur is None:
                continue
            for k in range(n):
                if mask >> k & 1 or not allowed(k, mask):
                    continue
                cand = (cur[0] + cost[j + 1][k + 1], cur[1] + (ids[k],))
                nxt = best[mask | 1 << k][k]
                if nxt is None or cand < nxt:
                    best[mask | 1 << k][k] = cand
    end = min(x for x in best[full] if x is not None)
    index = {sid: i for i, sid in enumerate(ids)}
    return [index[sid] for sid in end[1]]


# ------------------------------------------------------------------ 계산
def plan(service: RouteService, req: VisitRequest) -> VisitResponse:
    from .service import _line, _meters_projector, build_model, GH_PROFILE

    points = [(req.origin.lat, req.origin.lon), *[(s.lat, s.lon) for s in req.stops]]
    zones = service._zones(req.demo)
    to_m = _meters_projector(points[0][0])
    ends = [transform(to_m, Point(lon, lat)) for lat, lon in points]
    near = {z.id for z in zones if any(transform(to_m, z.geometry).distance(p) <= NEAR_M for p in ends)}
    block = frozenset(z.id for z in zones if z.id not in near)
    rules = rules_for(req.profile, "safest", req.mode)
    gh_profile = GH_PROFILE[req.mode]
    hard = build_model(rules, zones, block)
    soft = build_model(rules, zones)
    lifted: set[str] = set()

    def route(pts: list[tuple[float, float]]) -> tuple[dict[str, Any], bool]:
        """막은 구역을 지키는 길, 없으면 막은 구역을 풀어(0.001) 다시 — (경로, 풀었는지)"""
        try:
            return service.gh.route(pts, profile=gh_profile, custom_model=hard), False
        except RouteNotFound:
            if not block:
                raise
            return service.gh.route(pts, profile=gh_profile, custom_model=soft), True

    def leg(pair: tuple[int, int]) -> tuple[tuple[int, int], dict[str, Any] | None, bool]:
        i, j = pair
        try:
            path, loosened = route([points[i], points[j]])
            return pair, path, loosened
        except RouteNotFound:
            return pair, None, False

    n = len(req.stops)
    pairs = [(i, j) for i in range(n + 1) for j in range(1, n + 1) if i != j]
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        legs = list(pool.map(leg, pairs))
    cost = [[0.0] * (n + 1) for _ in range(n + 1)]
    time = [[0.0] * (n + 1) for _ in range(n + 1)]
    for (i, j), path, loosened in legs:
        cost[i][j] = path["distance"] if path else UNREACHABLE
        time[i][j] = path["time"] / 1000 if path else 0
        if path and loosened:
            lifted.update(z.id for z in zones if z.id in block and _line(path["points"]).intersects(z.geometry))
    if all(cost[0][j] >= UNREACHABLE for j in range(1, n + 1)):
        raise RouteNotFound("출발점에서 방문할 집으로 가는 길이 없습니다")

    tiers = [s.tier for s in req.stops]
    ids = [s.id for s in req.stops]

    def build(by_priority: bool) -> VisitPlan:
        order = solve(cost, tiers, ids, by_priority)
        path, loosened = route([points[0], *[points[k + 1] for k in order]])
        line = _line(path["points"])
        if loosened:
            lifted.update(z.id for z in zones if z.id in block and line.intersects(z.geometry))
        prev = 0
        out = []
        for seq, k in enumerate(order, 1):
            out.append(VisitLeg(id=ids[k], seq=seq, tier=tiers[k], leg_distance_m=round(min(cost[prev][k + 1], UNREACHABLE)),
                                leg_duration_s=round(time[prev][k + 1])))
            prev = k + 1
        return VisitPlan(order=out, distance_m=round(path["distance"]), duration_s=round(path["time"] / 1000),
                         geometry=path["points"], still_inside=[z.id for z in zones if line.intersects(z.geometry)])

    shortest, priority = build(False), build(True)
    return VisitResponse(mode=req.mode, shortest=shortest, priority=priority, blocked_zones=sorted(lifted),
                         hazards_ok=getattr(service.source(req.demo), "ok", True))
