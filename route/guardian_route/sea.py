"""B11 해상 → 최근접 항 → 육상 경로: 해상 판정, 항구 고르기, 거리·방위, 자동 대피소.

바다에는 도로가 없어 GraphHopper가 못 쓴다. 그래서 해상 구간은 출발 좌표 → 항구 접안점(berth)까지 육지·방파제를
돌아가는 바닷길(격자 최단 경로를 편 꺾은선)과 직선 방위로 안내하고, 항구의 육상 연결 지점(land_point)부터는 기존 /api/route 계산(위험 구역 회피·사용자 유형 규칙)을 그대로 쓴다.

데이터 (둘 다 route/data, 이미지에 포함 — route 서버는 DB를 읽지 않는다):
  land.geojson   OSM 해안선으로 만든 육지 다각형 (scripts/build_land.py). 이 밖이면 해상.
  ports.geojson  구룡포 일대 항·포구 12곳 (scripts/build_ports.py, 같은 내용이 DB ports 표에도 적재된다)
대피소: api `GET /api/v1/dashboard/layers/shelters` (공개 레이어). 풍랑 특보는 이 서버가 보지 않는다 —
앱은 대시보드 특보(warnings), AI는 get_weather_warnings로 붙인다.
"""

from __future__ import annotations

import heapq
import json
import logging
import math
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

import httpx
import numpy as np
import shapely
from shapely.geometry import LineString, Point, shape
from shapely.geometry.base import BaseGeometry
from shapely.ops import transform

from .hazards import Hazard

log = logging.getLogger("guardian_route")

DATA = Path(__file__).resolve().parent.parent / "data"
LAND_FILE = DATA / "land.geojson"
PORTS_FILE = DATA / "ports.geojson"

# 해안선에서 이 거리 안은 육지로 본다 (GPS 오차·방파제 위·물가에 선 사람을 바다로 보지 않게)
SHORE_TOLERANCE_M = 30.0
# 해상 구간 길찾기 (사용자 요청 2026-10-05: 방파제를 가로지르지 않게). 육지·방파제(land.geojson)에서 CLEARANCE_M 떨어진
# 바다 칸만 지나는 격자 최단 경로를 구한 뒤, 직선으로 이어도 육지를 안 지나는 점들은 하나로 펴서 꺾는 점만 남긴다.
CELL_M = 25.0                # 격자 칸 크기
CLEARANCE_M = 15.0           # 배가 육지·방파제와 떨어지는 거리 (격자 칸 기준) — 이보다 가까운 칸은 비싸게(NEAR_COST)
# 2026-10-05 수정: 해안선 가까운 칸을 아예 막으면 방파제 안쪽 접안점 근처에 칸이 없어, 가장 가까운 칸이 방파제 바깥이 되고
# 그 칸과 접안점을 잇는 끝 구간이 육지를 가로질렀다(무작위 400곳 중 127곳). 그래서
#   - 육지만 아니면 칸으로 쓰되, 해안 가까운 칸으로의 이동은 실제 선분이 육지와 안 겹칠 때만 허용하고 비용을 높인다
#   - 출발점·접안점은 '육지를 안 지나고 바로 닿는' 가장 가까운 칸에 붙인다
SAFE_M = CELL_M * math.sqrt(2) / 2 + 1.0  # 두 끝 칸이 모두 이보다 멀면 그 사이 선분은 육지를 지날 수 없다 (검사 생략)
NEAR_COST = 3.0              # 해안 CLEARANCE_M 안 칸으로 가는 비용 배수 (먼바다를 우선)
SNAP_CANDIDATES = 400        # 출발점·접안점에 붙일 칸을 찾을 때 가까운 순으로 볼 칸 수
LOS_CLEARANCE_M = 8.0        # 펴기(직선 연결)할 때 지켜야 할 거리. 출발점·접안점과 잇는 선분은 육지만 안 지나면 된다
SEARCH_MARGIN_M = 1500.0     # 출발점·항구를 둘러싼 이 여백 안에서만 찾는다 (곶을 돌아가는 길까지 들어가게)
CANDIDATE_PORTS = 5          # 직선 거리로 가까운 이 수의 항구만 실제 길이를 잰다
ALTERNATIVES = 2
CACHE_S = 60.0
DEFAULT_API_URL = "http://api:8000"

BEARING_LABELS = ["북쪽", "북북동쪽", "북동쪽", "동북동쪽", "동쪽", "동남동쪽", "남동쪽", "남남동쪽",
                  "남쪽", "남남서쪽", "남서쪽", "서남서쪽", "서쪽", "서북서쪽", "북서쪽", "북북서쪽"]


class OutsideArea(ValueError):
    """육지 자료 범위(구룡포 일대) 밖 좌표 — 해상인지 판단할 수 없다."""


@dataclass(frozen=True)
class Port:
    id: str
    name: str
    kind: str
    berth: tuple[float, float]       # (lat, lon) 배를 댈 곳 = 해상 구간 도착점
    land_point: tuple[float, float]  # (lat, lon) 도로와 이어지는 곳 = 육상 경로 출발점


@dataclass(frozen=True)
class PortChoice:
    port: Port
    distance_m: float                # 바닷길 길이 (육지·방파제를 돌아가는 길), 못 찾으면 직선 거리
    bearing_deg: float               # 출발점 → 접안점 직선 방위
    straight_m: float                # 직선 거리
    path: tuple[tuple[float, float], ...]  # (lat, lon) 출발점 → 꺾는 점들 → 접안점
    reachable: bool = True           # False면 바닷길을 못 찾음 (path는 직선)

    @property
    def direct(self) -> bool:
        """꺾지 않고 바로 갈 수 있음"""
        return self.reachable and len(self.path) == 2


def distance_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    """두 (lat, lon) 사이 대권 거리 (m)."""
    p = math.pi / 180
    h = (math.sin((b[0] - a[0]) * p / 2) ** 2
         + math.cos(a[0] * p) * math.cos(b[0] * p) * math.sin((b[1] - a[1]) * p / 2) ** 2)
    return 12_742_000 * math.asin(math.sqrt(h))


def bearing_deg(a: tuple[float, float], b: tuple[float, float]) -> float:
    """a에서 b로 가는 진북 기준 방위 (0~360, 시계 방향)."""
    la1, la2 = math.radians(a[0]), math.radians(b[0])
    dlon = math.radians(b[1] - a[1])
    y = math.sin(dlon) * math.cos(la2)
    x = math.cos(la1) * math.sin(la2) - math.sin(la1) * math.cos(la2) * math.cos(dlon)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def bearing_label(deg: float) -> str:
    """16방위 한글 (예: 315 → 북서쪽)."""
    return BEARING_LABELS[int((deg % 360) / 22.5 + 0.5) % 16]


def _to_m(lat0: float):
    """위도 lat0 근처에서 (lon, lat) 도 → m 평면 (수 km 범위라 등장방형 근사로 충분)."""
    kx = 111_320 * math.cos(math.radians(lat0))
    return lambda x, y, z=None: (x * kx, y * 111_320)


class SeaChart:
    """육지 다각형 + 항구 목록으로 해상 판정과 항구 고르기를 한다. 테스트는 land·ports를 직접 넣는다."""

    def __init__(self, land: BaseGeometry, ports: list[Port], bounds: tuple[float, float, float, float] | None = None):
        self.land = land
        self.ports = ports
        self.bounds = bounds or land.envelope.bounds  # (min lon, min lat, max lon, max lat)
        # 길찾기용 m 평면 (범위 가운데 위도 기준 하나로 고정)
        self._kx = 111_320 * math.cos(math.radians((self.bounds[1] + self.bounds[3]) / 2))
        land_m = transform(lambda x, y, z=None: (x * self._kx, y * 111_320), land)
        self._land_m = land_m
        self._blocked = land_m.buffer(CLEARANCE_M)   # 이 안 칸은 비싸게
        self._safe = land_m.buffer(SAFE_M)           # 이 밖 칸끼리 이동은 검사 없이 안전
        self._los = land_m.buffer(LOS_CLEARANCE_M)
        for g in (self._land_m, self._blocked, self._safe, self._los):
            shapely.prepare(g)

    def _xy(self, lat: float, lon: float) -> tuple[float, float]:
        return lon * self._kx, lat * 111_320

    def _latlon(self, x: float, y: float) -> tuple[float, float]:
        return y / 111_320, x / self._kx

    @classmethod
    def from_files(cls, land_file: Path = LAND_FILE, ports_file: Path = PORTS_FILE) -> SeaChart:
        land_fc = json.loads(Path(land_file).read_text(encoding="utf-8"))
        feat = land_fc["features"][0]
        bbox = (feat.get("properties") or {}).get("bbox")
        ports = [_port(f["properties"]) for f in json.loads(Path(ports_file).read_text(encoding="utf-8"))["features"]]
        return cls(shape(feat["geometry"]), ports, tuple(bbox) if bbox else None)

    def is_at_sea(self, lat: float, lon: float) -> bool:
        minx, miny, maxx, maxy = self.bounds
        if not (minx <= lon <= maxx and miny <= lat <= maxy):
            raise OutsideArea(f"{lat},{lon}은 구룡포 일대(해상 판정 범위) 밖입니다")
        pt = Point(lon, lat)
        if self.land.contains(pt):
            return False
        to_m = _to_m(lat)
        return transform(to_m, self.land).distance(transform(to_m, pt)) > SHORE_TOLERANCE_M

    def rank_ports(self, lat: float, lon: float) -> list[PortChoice]:
        """바닷길(육지·방파제를 돌아가는 길)이 짧은 순. 직선으로 가까운 CANDIDATE_PORTS곳만 잰다.
        바닷길을 못 찾은 항구(다른 바다 쪽 등)는 직선으로 두고 맨 뒤로."""
        here = (lat, lon)
        cands = sorted(self.ports, key=lambda p: distance_m(here, p.berth))[:CANDIDATE_PORTS]
        paths = self.sea_paths(here, [p.berth for p in cands])
        out = []
        for p, path in zip(cands, paths):
            straight = distance_m(here, p.berth)
            if path is None:
                out.append(PortChoice(p, straight, bearing_deg(here, p.berth), straight, (here, p.berth), reachable=False))
            else:
                length = sum(distance_m(a, b) for a, b in zip(path, path[1:]))
                out.append(PortChoice(p, length, bearing_deg(here, p.berth), straight, tuple(path)))
        return sorted(out, key=lambda c: (not c.reachable, c.distance_m))

    def sea_paths(self, start: tuple[float, float], ends: list[tuple[float, float]]) -> list[list[tuple[float, float]] | None]:
        """start에서 각 end까지 바다로만 가는 경로 [(lat, lon), …] (못 가면 None). 격자 다익스트라 한 번으로 모두 구한다."""
        pts = [self._xy(*start)] + [self._xy(*e) for e in ends]
        bx0, by0 = self._xy(self.bounds[1], self.bounds[0])
        bx1, by1 = self._xy(self.bounds[3], self.bounds[2])
        x0 = max(bx0, min(p[0] for p in pts) - SEARCH_MARGIN_M)
        x1 = min(bx1, max(p[0] for p in pts) + SEARCH_MARGIN_M)
        y0 = max(by0, min(p[1] for p in pts) - SEARCH_MARGIN_M)
        y1 = min(by1, max(p[1] for p in pts) + SEARCH_MARGIN_M)
        nx, ny = int((x1 - x0) / CELL_M) + 1, int((y1 - y0) / CELL_M) + 1
        gx, gy = np.meshgrid(x0 + np.arange(nx) * CELL_M, y0 + np.arange(ny) * CELL_M)  # [row=y, col=x]
        free = ~shapely.contains_xy(self._land_m, gx, gy)          # 육지만 아니면 칸
        near = shapely.contains_xy(self._blocked, gx, gy).ravel()   # 해안 CLEARANCE_M 안 → 비용 NEAR_COST
        unsafe = shapely.contains_xy(self._safe, gx, gy).ravel()    # 이동할 때 선분 검사 필요
        free_idx = np.flatnonzero(free)
        if free_idx.size == 0:
            return [None] * len(ends)
        flat_x, flat_y = gx.ravel(), gy.ravel()

        def crosses(x0_: float, y0_: float, x1_: float, y1_: float) -> bool:
            return self._land_m.intersects(LineString([(x0_, y0_), (x1_, y1_)]))

        def cell_of(x: float, y: float) -> int | None:
            """육지를 지나지 않고 바로 닿는 가장 가까운 칸 (없으면 None)"""
            d = (flat_x[free_idx] - x) ** 2 + (flat_y[free_idx] - y) ** 2
            for k in np.argsort(d)[:SNAP_CANDIDATES]:
                cell = int(free_idx[int(k)])
                if not crosses(x, y, float(flat_x[cell]), float(flat_y[cell])):
                    return cell
            return None

        src = cell_of(*pts[0])
        if src is None:
            return [None] * len(ends)
        goals: dict[int, list[int]] = {}
        for i, p in enumerate(pts[1:]):
            g = cell_of(*p)
            if g is not None:
                goals.setdefault(g, []).append(i)
        dist = {src: 0.0}
        prev: dict[int, int] = {}
        heap = [(0.0, src)]
        left = set(goals)
        flat_free = free.ravel()
        steps = [(dr, dc, CELL_M * math.hypot(dr, dc)) for dr in (-1, 0, 1) for dc in (-1, 0, 1) if dr or dc]
        while heap and left:
            d, cur = heapq.heappop(heap)
            if d > dist.get(cur, math.inf):
                continue
            left.discard(cur)
            r, c = divmod(cur, nx)
            for dr, dc, cost in steps:
                rr, cc = r + dr, c + dc
                if not (0 <= rr < ny and 0 <= cc < nx):
                    continue
                nxt = rr * nx + cc
                if not flat_free[nxt]:
                    continue
                if (unsafe[cur] or unsafe[nxt]) and crosses(flat_x[cur], flat_y[cur], flat_x[nxt], flat_y[nxt]):
                    continue          # 얇은 방파제·곶을 가로지르는 이동
                nd = d + cost * (NEAR_COST if near[nxt] else 1.0)
                if nd < dist.get(nxt, math.inf):
                    dist[nxt], prev[nxt] = nd, cur
                    heapq.heappush(heap, (nd, nxt))

        out: list[list[tuple[float, float]] | None] = [None] * len(ends)
        for goal, idxs in goals.items():
            if goal not in dist:
                continue
            cells = [goal]
            while cells[-1] != src:
                cells.append(prev[cells[-1]])
            for i in idxs:
                line = [pts[0]] + [(float(flat_x[k]), float(flat_y[k])) for k in reversed(cells)] + [pts[i + 1]]
                out[i] = [self._latlon(x, y) for x, y in self._straighten(line)]
        return out

    def _straighten(self, line: list[tuple[float, float]]) -> list[tuple[float, float]]:
        """격자 경로를 펴서 꺾는 점만 남긴다. 처음·끝 점(출발점·접안점)과 잇는 선분은 육지만 안 지나면 되고,
        중간 선분은 육지·방파제에서 LOS_CLEARANCE_M 떨어져야 한다. 펴지 못하면 원래 이웃 점으로 잇는데,
        이웃 점끼리는 탐색·붙이기 때 이미 육지를 안 지나는 것을 확인했다."""
        last = len(line) - 1

        def clear(i: int, j: int) -> bool:
            seg = LineString([line[i], line[j]])
            if seg.length == 0:
                return True
            return not (self._land_m if i == 0 or j == last else self._los).intersects(seg)

        out, i = [line[0]], 0
        while i < last:
            j = i + 1
            while j < last and clear(i, j + 1):
                j += 1
            out.append(line[j])
            i = j
        return out


def _port(p: dict[str, Any]) -> Port:
    return Port(id=p["id"], name=p["name"], kind=p.get("kind", "other"),
                berth=(p["berth"][1], p["berth"][0]), land_point=(p["land_point"][1], p["land_point"][0]))


# ------------------------------------------------------------------ 대피소 (목적지를 안 주면 자동 선택)
@dataclass(frozen=True)
class Shelter:
    id: Any
    name: str
    lat: float
    lon: float
    unsuitable_for: tuple[str, ...] = ()


class ShelterSource(Protocol):
    def shelters(self) -> list[Shelter]: ...


class ApiShelterSource:
    """api 공개 지도 레이어의 대피소. CACHE_S 동안 재사용, 못 읽으면 마지막 값(없으면 빈 목록)."""

    def __init__(self, base_url: str | None = None, client: httpx.Client | None = None, cache_s: float = CACHE_S):
        self.http = client or httpx.Client(base_url=base_url or os.environ.get("ROUTE_RISK_API_URL") or DEFAULT_API_URL,
                                           timeout=3.0)
        self.cache_s = cache_s
        self._cached: list[Shelter] | None = None
        self._at = 0.0

    def shelters(self) -> list[Shelter]:
        if self._cached is not None and time.monotonic() - self._at < self.cache_s:
            return self._cached
        try:
            res = self.http.get("/api/v1/dashboard/layers/shelters")
            res.raise_for_status()
            features = res.json()["features"]
        except (httpx.HTTPError, ValueError, KeyError) as e:
            log.warning("대피소 레이어를 못 읽음 (%s)", type(e).__name__)
            return self._cached or []
        self._cached = [Shelter(id=f["properties"].get("id"), name=f["properties"]["name"],
                                lat=f["geometry"]["coordinates"][1], lon=f["geometry"]["coordinates"][0],
                                unsuitable_for=tuple(f["properties"].get("unsuitable_for") or ()))
                        for f in features]
        self._at = time.monotonic()
        return self._cached


def pick_shelter(origin: tuple[float, float], shelters: list[Shelter], zones: list[Hazard]) -> tuple[Shelter | None, str | None]:
    """origin에서 직선으로 가장 가까운 '갈 만한' 대피소. AI get_safe_shelters·앱과 같은 규칙:
    지금 침수·산사태 영역 안이면 제외, 침수 중 지하 시설 제외, 발효 중인 재난에 비추천(unsuitable_for)이면 제외.
    갈 만한 곳이 없으면 가장 가까운 곳 + 경고 문구."""
    if not shelters:
        return None, "대피소 목록을 읽지 못했습니다"
    active = {z.kind for z in zones}
    flood = "flood" in active

    def reason(s: Shelter) -> str | None:
        pt = Point(s.lon, s.lat)
        hit = next((z for z in zones if z.geometry.intersects(pt)), None)
        if hit:
            return f"위험 영역 안({hit.name or hit.id})"
        if flood and "지하" in s.name:
            return "침수 중 지하 시설"
        if active & set(s.unsuitable_for):
            return "지금 재난에 비추천"
        return None

    ranked = sorted(shelters, key=lambda s: distance_m(origin, (s.lat, s.lon)))
    safe = [s for s in ranked if reason(s) is None]
    if safe:
        return safe[0], None
    return ranked[0], f"갈 만한 대피소가 없어 가장 가까운 곳으로 안내합니다 — {reason(ranked[0])}"
