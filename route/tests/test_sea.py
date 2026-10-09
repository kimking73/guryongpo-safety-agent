"""B11 /api/route/sea — 응답 형식(앱 C8·AI가 기대는 계약)과 기본 규칙. 가짜 GraphHopper, 작은 가짜 지도.

판정 세부(항로 막힘 기준 등)는 B11 마무리 때 바뀔 수 있다 (2026-10-05 사용자) — 여기서는 계약 위주로 본다.
"""

import httpx
from fastapi.testclient import TestClient
from shapely.geometry import LineString, box

from guardian_route.api import app, get_service
from guardian_route.gh import GraphHopperClient
from guardian_route.hazards import Hazard, circle
from guardian_route.polyline import decode
from guardian_route.sea import Port, SeaChart, Shelter, bearing_deg, bearing_label, distance_m, pick_shelter
from guardian_route.service import RouteService

# 서쪽 절반(경도 129.55 이하)이 육지인 가짜 지도
LAND = box(129.50, 35.95, 129.55, 36.02)
BOUNDS = (129.50, 35.95, 129.60, 36.02)
PORTS = [
    Port("a", "가항", "other", berth=(35.990, 129.5505), land_point=(35.990, 129.5495)),
    Port("b", "나항", "other", berth=(35.970, 129.5505), land_point=(35.970, 129.5495)),
    Port("c", "다항", "other", berth=(36.010, 129.5505), land_point=(36.010, 129.5495)),
]
PATH = {"distance": 500.0, "time": 400000, "points": "oktzEe|vuWl@p@BCpAhB", "ascend": 0, "descend": 0}


class NoHazards:
    def hazards(self):
        return []


class Shelters:
    def __init__(self, items):
        self.items = items

    def shelters(self):
        return self.items


def client(gh_status=200, shelters=None, hazards=None):
    def gh(req: httpx.Request) -> httpx.Response:
        if gh_status != 200:
            return httpx.Response(gh_status, json={"message": "down"})
        return httpx.Response(200, json={"paths": [PATH]})

    service = RouteService(client=GraphHopperClient(base_url="http://gh", transport=httpx.MockTransport(gh)),
                           hazards=hazards or NoHazards(), chart=SeaChart(LAND, PORTS, BOUNDS),
                           shelters=Shelters(shelters if shelters is not None else [Shelter(1, "언덕 대피소", 35.99, 129.53)]))
    app.dependency_overrides[get_service] = lambda: service
    return TestClient(app)


def test_at_sea_returns_port_sea_leg_and_land_route():
    res = client().post("/api/route/sea", json={"origin": {"lat": 35.991, "lon": 129.57}})
    assert res.status_code == 200
    body = res.json()
    assert body["at_sea"] is True
    assert body["port"]["name"] == "가항"
    assert set(body["port"]) == {"id", "name", "kind", "berth", "land_point"}
    assert body["port"]["land_point"] == {"lat": 35.990, "lon": 129.5495}
    leg = body["sea_leg"]
    assert 1700 < leg["straight_m"] < 1900 and leg["bearing_label"] == "서쪽"
    assert leg["direct"] is True and leg["path_found"] is True
    assert abs(leg["distance_m"] - leg["straight_m"]) < 5
    path = decode(leg["path"])                                   # 출발 → 접안점 꺾은선 (lat, lon)
    assert path[0] == (35.991, 129.57) and path[-1] == (35.99, 129.5505)
    assert [a["name"] for a in leg["alternatives"]] == ["다항", "나항"]
    assert body["destination"]["name"] == "언덕 대피소"            # 목적지 생략 → 대피소 자동 선택
    assert body["land_route"]["distance_m"] == 500 and body["land_route_error"] is None


def test_on_land_returns_plain_route_only():
    body = client().post("/api/route/sea", json={"origin": {"lat": 35.99, "lon": 129.52},
                                                 "destination": {"lat": 35.98, "lon": 129.53}}).json()
    assert body["at_sea"] is False and body["port"] is None and body["sea_leg"] is None
    assert body["destination"] == {"name": None, "lat": 35.98, "lon": 129.53, "note": None}
    assert body["land_route"]["distance_m"] == 500


def test_shore_within_30m_counts_as_land():
    chart = SeaChart(LAND, PORTS, BOUNDS)
    assert chart.is_at_sea(35.99, 129.5502) is False     # 해안선에서 약 20m
    assert chart.is_at_sea(35.99, 129.5510) is True      # 약 90m


def test_sea_check_only_answers_at_sea():
    # 경로 엔진이 죽어도 판별은 된다 (경로 계산 없음)
    c = client(gh_status=500)
    assert c.post("/api/route/sea/check", json={"origin": {"lat": 35.991, "lon": 129.57}}).json() == {"at_sea": True}
    assert c.post("/api/route/sea/check", json={"origin": {"lat": 35.99, "lon": 129.52}}).json() == {"at_sea": False}
    assert c.post("/api/route/sea/check", json={"origin": {"lat": 37.5, "lon": 127.0}}).status_code == 422


def test_outside_area_is_422():
    assert client().post("/api/route/sea", json={"origin": {"lat": 37.5, "lon": 127.0}}).status_code == 422


def test_engine_down_keeps_sea_guidance():
    body = client(gh_status=500).post("/api/route/sea", json={"origin": {"lat": 35.991, "lon": 129.57}}).json()
    assert body["port"]["name"] == "가항" and body["land_route"] is None
    assert "경로를 구하지 못했습니다" in body["land_route_error"]


def test_engine_down_on_land_is_503():
    assert client(gh_status=500).post("/api/route/sea", json={"origin": {"lat": 35.99, "lon": 129.52}}).status_code == 503


def test_no_shelters_reports_reason():
    body = client(shelters=[]).post("/api/route/sea", json={"origin": {"lat": 35.991, "lon": 129.57}}).json()
    assert body["land_route"] is None and body["land_route_error"] == "대피소 목록을 읽지 못했습니다"


def test_pick_shelter_skips_hazard_and_underground_during_flood():
    near = Shelter(1, "가까운 곳", 35.990, 129.540)
    under = Shelter(2, "지하주차장", 35.990, 129.538)
    far = Shelter(3, "먼 곳", 35.990, 129.520)
    flood = Hazard("flood-1", "flood", circle(35.990, 129.540, 50), name="침수 경보")
    chosen, note = pick_shelter((35.990, 129.545), [near, under, far], [flood])
    assert chosen.name == "먼 곳" and note is None
    chosen, note = pick_shelter((35.990, 129.545), [near], [flood])
    assert chosen.name == "가까운 곳" and "위험 영역 안" in note


def test_sea_leg_goes_around_breakwater():
    """방파제(얇은 육지)가 가로막으면 끝을 돌아간다 — 직선으로 가로지르지 않는다 (사용자 요청 2026-10-05)"""
    wall = box(129.558, 35.975, 129.5585, 36.005)                 # 남북으로 긴 방파제 (폭 약 45m)
    chart = SeaChart(LAND.union(wall), PORTS, BOUNDS)
    ranked = chart.rank_ports(35.990, 129.57)
    for c in ranked:                                              # 모든 항구가 방파제 안쪽 — 끝을 돌아서만 간다
        assert c.reachable and not c.direct
        assert not LineString([(lon, lat) for lat, lon in c.path]).intersects(wall)
    assert ranked[0].port.name == "다항"                          # 북쪽 끝으로 돌면 다항이 가장 가깝다
    behind = next(c for c in ranked if c.port.name == "가항")      # 방파제 바로 뒤 항구: 직선 1.75km → 끝까지 돌아 약 3.9km
    assert behind.distance_m > behind.straight_m + 1500


def test_bearing_and_distance():
    assert bearing_label(bearing_deg((35.99, 129.57), (35.99, 129.55))) == "서쪽"
    assert bearing_label(bearing_deg((35.99, 129.55), (36.00, 129.55))) == "북쪽"
    assert bearing_label(315) == "북서쪽"
    assert 1100 < distance_m((35.99, 129.55), (36.00, 129.55)) < 1120


def test_real_data_files_load():
    chart = SeaChart.from_files()
    assert len(chart.ports) >= 10 and any(p.name == "구룡포항" for p in chart.ports)
    assert chart.is_at_sea(35.9870, 129.5450) is False    # 구룡포읍 시가지
    assert chart.is_at_sea(35.9900, 129.5800) is True     # 구룡포항 앞바다
    best = chart.rank_ports(35.9871, 129.5700)[0]
    assert best.port.name == "구룡포항" and best.reachable
    # 실제 방파제(OSM man_made=breakwater)를 가로지르지 않는다
    leg = LineString([(lon, lat) for lat, lon in best.path])
    assert leg.intersection(chart.land).length * 111_000 < 1


def test_real_data_paths_never_cross_land():
    """방파제 안쪽 접안점·해안 가까운 출발점에서도 바닷길이 육지를 지나지 않는다 (2026-10-05: 무작위 400곳 중 127곳이
    끝 구간에서 방파제·곶을 20m 남짓 가로질렀다 — 하정1리·병포리 포구 등). 고정 시드 표본으로 다시 확인"""
    import random
    from shapely.ops import transform
    chart = SeaChart.from_files()
    to_m = lambda x, y, z=None: (x * chart._kx, y * 111_320)
    rnd = random.Random(1)
    checked = 0
    while checked < 40:
        lat, lon = rnd.uniform(35.93, 36.04), rnd.uniform(129.53, 129.60)
        if not chart.is_at_sea(lat, lon):
            continue
        checked += 1
        for choice in chart.rank_ports(lat, lon):
            if not choice.reachable:
                continue
            leg = transform(to_m, LineString([(lo, la) for la, lo in choice.path]))
            assert leg.intersection(chart._land_m).length < 1.0, (lat, lon, choice.port.name)
    # 예전에 끝 구간이 방파제를 가로지르던 곳
    for lat, lon in [(35.95231, 129.56836), (35.97945, 129.56146)]:
        best = chart.rank_ports(lat, lon)[0]
        assert best.reachable
        leg = transform(to_m, LineString([(lo, la) for la, lo in best.path]))
        assert leg.intersection(chart._land_m).length < 1.0


def test_unreachable_ports_draw_no_line():
    """영일만 쪽까지 넓은 범위 표본: 가장 좋은 항구는 늘 바닷길이 있고, 바닷길을 못 찾은 항구는 직선(육지를 뚫는 선)
    대신 선 없이(출발점 하나) 돌려준다 (2026-10-05: 못 찾으면 직선으로 그리던 54구간)"""
    import random
    chart = SeaChart.from_files()
    rng = random.Random(7)
    checked = 0
    while checked < 60:
        lat, lon = rng.uniform(35.92, 36.04), rng.uniform(129.48, 129.60)
        if not chart.is_at_sea(lat, lon):
            continue
        checked += 1
        ranked = chart.rank_ports(lat, lon)
        assert ranked[0].reachable, (lat, lon)
        for c in ranked[:3]:
            if not c.reachable:
                assert len(c.path) == 1                              # 못 찾으면 선을 그리지 않는다
                continue
            line = LineString([chart._xy(a, b) for a, b in c.path])
            assert line.intersection(chart._land_m).length < 1, (lat, lon, c.port.name)
