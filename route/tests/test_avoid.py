"""위험 구역 회피: custom_model 조립, avoided·still_inside 계산, 판정 엔진 영역 읽기, 놓친 구역 넓혀 재요청 (가짜 GraphHopper)
+ 임시 데이터로 실제 우회(live)."""

import json

import httpx
import pytest
from fastapi.testclient import TestClient
from shapely.geometry import box

from guardian_route import polyline
from guardian_route.api import app, get_service
from guardian_route.gh import GraphHopperClient
from guardian_route.hazards import GeoJsonHazardSource, Hazard, RiskAreaHazardSource
from guardian_route.service import AVOID_PRIORITY, RouteService, area_id

BODY = {"origin": {"lat": 35.9905, "lon": 129.5490}, "destination": {"lat": 35.9905, "lon": 129.5520}}

# 구역 A: 기본 경로(가로 직선)가 가로지른다. 구역 B: 우회 경로의 윗길에 걸친다. 먼 구역: 어느 경로에도 안 걸린다.
ZONE_A = Hazard("flood-001", "flood", box(129.5500, 35.9900, 129.5510, 35.9910))
ZONE_B = Hazard("landslide-001", "landslide", box(129.5505, 35.9918, 129.5506, 35.9922))
FAR = Hazard("flood-099", "flood", box(129.5600, 35.9800, 129.5601, 35.9801))

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
    assert "custom_model" not in sent[-1]         # 마지막은 avoided 계산용 기본 경로


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
    c, _ = client(Hazards(FAR))
    res = c.post("/api/route", json=BODY).json()
    assert res["avoided"] == [] and res["still_inside"] == []


def test_no_zones_means_one_plain_request():
    c, sent = client(Hazards())
    c.post("/api/route", json=BODY)
    assert len(sent) == 1 and "custom_model" not in sent[0]


def test_widens_a_zone_graphhopper_missed_until_route_is_clear():
    """GraphHopper가 구역을 못 보고 가로지르면(실제로 있었던 일) 그 구역만 넓혀 다시 요청한다."""
    sent: list[dict] = []

    def handler(req: httpx.Request) -> httpx.Response:
        body = json.loads(req.content)
        sent.append(body)
        model = body.get("custom_model")
        if not model:
            return httpx.Response(200, json={"paths": [{"distance": 300.0, "time": 216_000, "points": BASE}]})
        # 원래 크기 구역이면 놓친 척 기본 경로, 넓힌 구역(가로 100m 넘음)이면 우회 경로
        ring = model["areas"]["features"][0]["geometry"]["coordinates"][0]
        wide = (max(x for x, _ in ring) - min(x for x, _ in ring)) * 90_000 > 100
        return httpx.Response(200, json={"paths": [{"distance": 1500.0, "time": 1_080_000, "points": SAFE if wide else BASE}]})

    gh = GraphHopperClient(base_url="http://gh", transport=httpx.MockTransport(handler))
    app.dependency_overrides[get_service] = lambda: RouteService(client=gh, hazards=Hazards(ZONE_A))
    res = TestClient(app).post("/api/route", json=BODY).json()
    assert res["geometry"] == SAFE and res["still_inside"] == [] and res["avoided"] == ["flood-001"]
    assert len(sent) == 3        # 원래 구역 → 50m 넓힘 → 기본 경로


def test_zone_containing_the_destination_is_not_widened():
    """도착지가 구역 안이면 어차피 지나야 하므로 넓혀 다시 요청하지 않는다."""
    dest_zone = Hazard("flood-050", "flood", box(129.5515, 35.9900, 129.5525, 35.9910))
    c, sent = client(Hazards(dest_zone))
    res = c.post("/api/route", json=BODY).json()
    assert res["still_inside"] == ["flood-050"] and len(sent) == 2


def test_area_id_is_graphhopper_safe():
    assert area_id("flood-001") == "flood_001"
    assert area_id("zone.a b") == "zone_a_b"


def test_sample_file_ignores_manholes():
    hs = GeoJsonHazardSource().hazards()
    assert {h.kind for h in hs} == {"flood", "landslide"}       # 맨홀은 회피하지 않는다 (사용자 결정 2026-10-02)
    assert len({h.id for h in hs}) == len(hs)                  # id 중복 없음
    assert all(h.name for h in hs)


def test_hazards_endpoint_returns_geojson_with_names():
    c, _ = client(GeoJsonHazardSource())
    res = c.get("/api/route/hazards").json()
    assert res["type"] == "FeatureCollection" and len(res["features"]) >= 3
    assert {"id", "kind", "name"} <= set(res["features"][0]["properties"])


# --- 판정 엔진 영역 (api GET /api/v1/risk/areas) ---

AREAS = {"type": "FeatureCollection", "features": [
    {"type": "Feature", "id": 7, "geometry": {"type": "MultiPolygon", "coordinates": [[[[129.55, 35.99], [129.551, 35.99], [129.551, 35.991], [129.55, 35.99]]]]},
     "properties": {"hazard": "flood", "level": "warning", "label": "침수 경보"}},
    {"type": "Feature", "id": 8, "geometry": {"type": "MultiPolygon", "coordinates": [[[[129.5, 35.9], [129.6, 35.9], [129.6, 36.0], [129.5, 35.9]]]]},
     "properties": {"hazard": "heavy_rain", "level": "warning", "label": "강우 경보"}},
    {"type": "Feature", "id": 9, "geometry": {"type": "Polygon", "coordinates": [[[129.54, 35.98], [129.541, 35.98], [129.541, 35.981], [129.54, 35.98]]]},
     "properties": {"hazard": "landslide", "level": "advisory", "label": "산사태 주의"}},
]}


def risk_source(handler):
    calls: list[httpx.Request] = []

    def record(req):
        calls.append(req)
        return handler(req)
    return RiskAreaHazardSource(client=httpx.Client(base_url="http://api", transport=httpx.MockTransport(record))), calls


def test_risk_areas_keep_flood_and_landslide_only_from_advisory():
    src, calls = risk_source(lambda r: httpx.Response(200, json=AREAS))
    hs = src.hazards()
    assert [(h.id, h.kind, h.name) for h in hs] == [("flood-7", "flood", "침수 경보"), ("landslide-9", "landslide", "산사태 주의")]
    assert calls[0].url.params["min_level"] == "advisory"     # 사용자 결정: 침수 "주의"부터 피함
    assert src.ok


def test_risk_areas_are_cached():
    src, calls = risk_source(lambda r: httpx.Response(200, json=AREAS))
    src.hazards(); src.hazards()
    assert len(calls) == 1


def test_risk_api_down_keeps_last_value_or_reports_not_ok():
    state = {"up": True}

    def handler(r):
        if not state["up"]:
            raise httpx.ConnectError("down")
        return httpx.Response(200, json=AREAS)
    src, _ = risk_source(handler)
    src.cache_s = 0
    assert len(src.hazards()) == 2
    state["up"] = False
    assert len(src.hazards()) == 2 and src.ok                  # 마지막 값

    fresh, _ = risk_source(lambda r: (_ for _ in ()).throw(httpx.ConnectError("down")))
    assert fresh.hazards() == [] and not fresh.ok              # 한 번도 못 받음 → 회피 없이, 응답에 알림


def test_route_reports_hazards_not_ok_when_risk_api_unreachable():
    src, _ = risk_source(lambda r: (_ for _ in ()).throw(httpx.ConnectError("down")))
    c, _ = client(src)
    assert c.post("/api/route", json=BODY).json()["hazards_ok"] is False


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
