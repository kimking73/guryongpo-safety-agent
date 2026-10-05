"""B11 해상 → 최근접 항 → 육상 경로: 해상 판정, 항구 고르기, 거리·방위, 자동 대피소.

바다에는 도로가 없어 GraphHopper가 못 쓴다. 그래서 해상 구간은 출발 좌표 → 항구 접안점(berth)의 직선 거리·방위로
안내하고, 항구의 육상 연결 지점(land_point)부터는 기존 /api/route 계산(위험 구역 회피·사용자 유형 규칙)을 그대로 쓴다.

데이터 (둘 다 route/data, 이미지에 포함 — route 서버는 DB를 읽지 않는다):
  land.geojson   OSM 해안선으로 만든 육지 다각형 (scripts/build_land.py). 이 밖이면 해상.
  ports.geojson  구룡포 일대 항·포구 12곳 (scripts/build_ports.py, 같은 내용이 DB ports 표에도 적재된다)
대피소: api `GET /api/v1/dashboard/layers/shelters` (공개 레이어). 풍랑 특보는 이 서버가 보지 않는다 —
앱은 대시보드 특보(warnings), AI는 get_weather_warnings로 붙인다.
"""

from __future__ import annotations

import json
import logging
import math
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

import httpx
from shapely.geometry import LineString, Point, shape
from shapely.geometry.base import BaseGeometry
from shapely.ops import substring, transform, unary_union

from .hazards import Hazard

log = logging.getLogger("guardian_route")

DATA = Path(__file__).resolve().parent.parent / "data"
LAND_FILE = DATA / "land.geojson"
PORTS_FILE = DATA / "ports.geojson"

# 해안선에서 이 거리 안은 육지로 본다 (GPS 오차·방파제 위·물가에 선 사람을 바다로 보지 않게)
SHORE_TOLERANCE_M = 30.0
# 직선 해상 구간이 육지를 이만큼 넘게 지나면 "막힌 항로"로 본다 (곶을 가로지르는 직선).
LAND_CROSSING_TOLERANCE_M = 30.0
# 단, 접안점 앞 이 거리는 검사하지 않는다 — 항구 안쪽 접안점은 방파제 뒤에 있어 직선이 방파제를 지나기 마련이다
HARBOUR_APPROACH_M = 300.0
# 막힌 직선 항로는 가로지른 육지 길이의 이 배수만큼 돌아간다고 보고 순위를 매긴다
DETOUR_FACTOR = 2.0
# 이보다 작은 육지 조각(바위섬)은 항로를 막지 않는다 (m²)
MIN_BLOCKING_AREA_M2 = 5_000.0
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
    distance_m: float
    bearing_deg: float
    clear: bool                      # 직선 항로가 육지를 가로지르지 않음 (False면 해안을 돌아가야 함)


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
        """바다로 가는 거리가 짧은 순. 직선 항로가 육지(곶·방파제)를 가로지르면 그 길이의 2배를 돌아가는 거리로 더한다
        (OSM 해안선은 방파제도 육지로 그린다). 작은 바위섬은 항로를 막지 않는 것으로 본다."""
        here = (lat, lon)
        to_m = _to_m(lat)
        land_m = transform(to_m, self.land)
        land_m = unary_union([g for g in getattr(land_m, "geoms", [land_m]) if g.area >= MIN_BLOCKING_AREA_M2])
        out = []
        for p in self.ports:
            leg = transform(to_m, LineString([(lon, lat), (p.berth[1], p.berth[0])]))
            open_sea = substring(leg, 0, max(0.0, leg.length - HARBOUR_APPROACH_M))
            crossing = open_sea.intersection(land_m).length if open_sea.length > 0 else 0.0
            out.append((distance_m(here, p.berth) + DETOUR_FACTOR * crossing,
                        PortChoice(p, distance_m(here, p.berth), bearing_deg(here, p.berth),
                                   crossing <= LAND_CROSSING_TOLERANCE_M)))
        return [c for _, c in sorted(out, key=lambda t: t[0])]


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
