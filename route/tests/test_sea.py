"""B11 /api/route/sea — 응답 형식(앱 C8·AI가 기대는 계약)과 기본 규칙. 가짜 GraphHopper, 작은 가짜 지도.

판정 세부(항로 막힘 기준 등)는 B11 마무리 때 바뀔 수 있다 (2026-10-05 사용자) — 여기서는 계약 위주로 본다.
"""

import httpx
from fastapi.testclient import TestClient
from shapely.geometry import box

from guardian_route.api import app, get_service
from guardian_route.gh import GraphHopperClient
from guardian_route.hazards import Hazard, circle
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
    assert 1700 < leg["distance_m"] < 1900 and leg["bearing_label"] == "서쪽" and leg["direct"] is True
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
    assert chart.rank_ports(35.9871, 129.5700)[0].port.name == "구룡포항"
