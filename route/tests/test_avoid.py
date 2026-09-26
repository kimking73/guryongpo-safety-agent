"""위험 구역 회피: custom_model 조립, avoided·still_inside 계산 (가짜 GraphHopper) + 임시 데이터로 실제 우회(live)."""

import json

import httpx
import pytest
from fastapi.testclient import TestClient
from shapely.geometry import box

from guardian_route import polyline
from guardian_route.api import app, get_service
from guardian_route.gh import GraphHopperClient
from guardian_route.hazards import GeoJsonHazardSource, Hazard
from guardian_route.service import AVOID_PRIORITY, RouteService, area_id

BODY = {"origin": {"lat": 35.9905, "lon": 129.5490}, "destination": {"lat": 35.9905, "lon": 129.5520}}

# 구역 A: 기본 경로(가로 직선)가 가로지른다. 구역 B: 우회 경로의 윗길에 걸친다. 맨홀: 어느 경로에도 안 걸린다.
ZONE_A = Hazard("flood-001", "flood", box(129.5500, 35.9900, 129.5510, 35.9910))
ZONE_B = Hazard("landslide-001", "landslide", box(129.5505, 35.9918, 129.5506, 35.9922))
MANHOLE = Hazard("manhole-001", "manhole", box(129.5600, 35.9800, 129.5601, 35.9801))

BASE = polyline.encode([(35.9905, 129.5490), (35.9905, 129.5520)])
SAFE = polyline.encode([(35.9905, 129.5490), (35.9920, 129.5490), (35.9920, 129.5520), (35.9905, 129.5520)])


class Hazards:
    def __init__(self, *items):
        self.items = list(items)

    def hazards(self):
        return self.items


def client(hazards) -> tuple[TestClient, list[dict]]:
    """custom_model이 있으면 우회 경로(SAFE), 없으면 기본 경로(BASE)를 주는 가짜 GraphHopper. 받은 요청 본문 목록도 돌려준다."""
    sent: list[dict] = []

    def handler(req: httpx.Request) -> httpx.Response:
        body = json.loads(req.content)
        sent.append(body)
        if "custom_model" in body:
            return httpx.Response(200, json={"paths": [{"distance": 1500.4, "time": 1_080_000, "points": SAFE}]})
        return httpx.Response(200, json={"paths": [{"distance": 300.0, "time": 216_000, "points": BASE}]})

    gh = GraphHopperClient(base_url="http://gh", transport=httpx.MockTransport(handler))
    service = RouteService(client=gh, hazards=hazards)
    app.dependency_overrides[get_service] = lambda: service
    return TestClient(app), sent


def test_sends_avoid_model_for_every_zone():
    c, sent = client(Hazards(ZONE_A, ZONE_B))
    c.post("/api/route", json=BODY)
    model = sent[0]["custom_model"]
    assert model["priority"] == [
        {"if": "in_flood_001", "multiply_by": str(AVOID_PRIORITY)},
        {"if": "in_landslide_001", "multiply_by": str(AVOID_PRIORITY)},
    ]
    assert [f["id"] for f in model["areas"]["features"]] == ["flood_001", "landslide_001"]
    assert model["areas"]["features"][0]["geometry"]["type"] == "Polygon"
    assert "custom_model" not in sent[1]          # 두 번째는 avoided 계산용 기본 경로


def test_reports_avoided_and_returns_safe_route():
    c, _ = client(Hazards(ZONE_A))
    res = c.post("/api/route", json=BODY).json()
    assert res["avoided"] == ["flood-001"] and res["still_inside"] == []
    assert res["geometry"] == SAFE and res["distance_m"] == 1500 and res["duration_s"] == 1080


def test_zone_the_safe_route_still_crosses_is_still_inside():
    c, _ = client(Hazards(ZONE_A, ZONE_B))
    res = c.post("/api/route", json=BODY).json()
    assert res["avoided"] == ["flood-001"]
    assert res["still_inside"] == ["landslide-001"]


def test_zone_off_both_routes_is_neither():
    c, _ = client(Hazards(MANHOLE))
    res = c.post("/api/route", json=BODY).json()
    assert res["avoided"] == [] and res["still_inside"] == []


def test_avoid_manholes_false_leaves_manholes_out():
    c, sent = client(Hazards(ZONE_A, MANHOLE))
    c.post("/api/route", json={**BODY, "avoid_manholes": False})
    assert [f["id"] for f in sent[0]["custom_model"]["areas"]["features"]] == ["flood_001"]

    c, sent = client(Hazards(MANHOLE))
    c.post("/api/route", json={**BODY, "avoid_manholes": False})
    assert len(sent) == 1 and "custom_model" not in sent[0]   # 피할 게 없으면 규칙 없이 한 번만


def test_area_id_is_graphhopper_safe():
    assert area_id("flood-001") == "flood_001"
    assert area_id("zone.a b") == "zone_a_b"


def test_sample_file_loads_with_manholes_as_small_circles():
    hs = GeoJsonHazardSource().hazards()
    kinds = {h.kind for h in hs}
    assert kinds == {"flood", "landslide", "manhole"}
    assert len({h.id for h in hs}) == len(hs)                  # id 중복 없음
    m = next(h for h in hs if h.kind == "manhole")
    minx, miny, maxx, maxy = m.geometry.bounds
    assert 8 < (maxy - miny) * 111_320 < 11                    # 지름 약 10m


def test_hazards_endpoint_returns_geojson():
    c, _ = client(GeoJsonHazardSource())
    res = c.get("/api/route/hazards").json()
    assert res["type"] == "FeatureCollection" and len(res["features"]) >= 3


def test_polyline_roundtrip():
    pts = [(35.9905, 129.556), (35.98692, 129.54797), (36.0, 129.6)]
    assert polyline.decode(polyline.encode(pts)) == pts


@pytest.mark.live
def test_live_detours_around_sample_flood_zone():
    """실제 graphhopper + 임시 데이터. 구룡포항 → 실내체육관 부근 기본 경로는 flood-001을 지나는데, 결과는 돌아가야 한다."""
    hazards = GeoJsonHazardSource()
    service = RouteService(client=GraphHopperClient(base_url="http://localhost:8989"), hazards=hazards)
    app.dependency_overrides[get_service] = lambda: service
    body = {"origin": {"lat": 35.9905, "lon": 129.5560}, "destination": {"lat": 35.9868, "lon": 129.5480}}
    res = TestClient(app).post("/api/route", json=body).json()
    assert "flood-001" in res["avoided"]
    zone = next(h for h in hazards.hazards() if h.id == "flood-001").geometry
    from shapely.geometry import LineString
    line = LineString([(lon, lat) for lat, lon in polyline.decode(res["geometry"])])
    assert not line.intersects(zone)
