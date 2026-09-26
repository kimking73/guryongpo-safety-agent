"""B7: 사용자 유형(profile)별 규칙, 이동 중 재계산 판단(/api/route/check). 가짜 GraphHopper + 실제(live)."""

import json

import httpx
import pytest
from fastapi.testclient import TestClient
from shapely.geometry import box

from guardian_route import polyline
from guardian_route.api import app, get_service
from guardian_route.gh import GraphHopperClient
from guardian_route.hazards import GeoJsonHazardSource, Hazard
from guardian_route.profiles import PROFILE_RULES
from guardian_route.service import RouteService

# 동서로 곧은 경로 (35.9905, 129.5490) → (35.9905, 129.5520), 약 270m
A, B = (35.9905, 129.5490), (35.9905, 129.5520)
LINE = polyline.encode([A, B])
DETOUR = polyline.encode([A, (35.9920, 129.5490), (35.9920, 129.5520), B])
ZONE = Hazard("flood-009", "flood", box(129.5500, 35.9900, 129.5510, 35.9910))   # LINE이 지나고 DETOUR는 안 지남


class Hazards:
    def __init__(self, *items):
        self.items = list(items)

    def hazards(self):
        return self.items


def client(hazards=(), detour_exists=True):
    """위험 구역 area가 있는 요청에는 DETOUR(없으면 LINE), 아니면 LINE을 주는 가짜 GraphHopper."""
    sent: list[dict] = []

    def handler(req: httpx.Request) -> httpx.Response:
        body = json.loads(req.content)
        sent.append(body)
        has_areas = "areas" in (body.get("custom_model") or {})
        pts = DETOUR if has_areas and detour_exists else LINE
        return httpx.Response(200, json={"paths": [{"distance": 300.0, "time": 216_000, "points": pts}]})

    gh = GraphHopperClient(base_url="http://gh", transport=httpx.MockTransport(handler))
    service = RouteService(client=gh, hazards=Hazards(*hazards))
    app.dependency_overrides[get_service] = lambda: service
    return TestClient(app), sent


def body(profile):
    return {"origin": {"lat": A[0], "lon": A[1]}, "destination": {"lat": B[0], "lon": B[1]}, "profile": profile}


# --- 사용자 유형별 규칙 ---

def test_adult_sends_no_rules():
    c, sent = client()
    c.post("/api/route", json=body("adult"))
    assert "custom_model" not in sent[0]


@pytest.mark.parametrize("profile", ["elderly", "wheelchair"])
def test_profile_rules_are_sent(profile):
    c, sent = client()
    assert c.post("/api/route", json=body(profile)).json()["profile"] == profile
    model = sent[0]["custom_model"]
    assert model["priority"] == PROFILE_RULES[profile]["priority"]
    assert model["speed"] == PROFILE_RULES[profile]["speed"]


def test_wheelchair_never_takes_steps_and_elderly_avoids_them():
    steps = {"if": "road_class == STEPS", "multiply_by": "0"}
    assert steps in PROFILE_RULES["wheelchair"]["priority"]
    assert {"if": "road_class == STEPS", "multiply_by": "0.3"} in PROFILE_RULES["elderly"]["priority"]


def test_profile_rules_combine_with_hazard_avoidance():
    c, sent = client([ZONE])
    res = c.post("/api/route", json=body("wheelchair")).json()
    safe, base = sent[0]["custom_model"], sent[1]["custom_model"]
    # 회피 경로: 휠체어 규칙 + 구역 회피
    assert safe["priority"][:len(PROFILE_RULES["wheelchair"]["priority"])] == PROFILE_RULES["wheelchair"]["priority"]
    assert safe["priority"][-1]["if"] == "in_flood_009" and "areas" in safe
    # 비교용 기본 경로: 휠체어 규칙은 같고 위험 구역만 뺀다
    assert base["priority"] == PROFILE_RULES["wheelchair"]["priority"] and "areas" not in base
    assert res["avoided"] == ["flood-009"]


# --- 이동 중 재계산 판단 ---

def check(c, lat, lon, geometry=LINE, **extra):
    return c.post("/api/route/check", json={
        "current": {"lat": lat, "lon": lon}, "destination": {"lat": B[0], "lon": B[1]},
        "geometry": geometry, **extra}).json()


def test_on_route_no_hazard_keeps_route():
    c, sent = client()
    res = check(c, 35.9905, 129.5495)
    assert res == {"reroute": False, "reasons": [], "off_route_m": 0, "hazards_ahead": [],
                   "arrived": False, "route": None}
    assert sent == []                          # 경로 엔진을 부르지 않는다


def test_small_gps_error_is_not_off_route():
    c, _ = client()
    res = check(c, 35.99065, 129.5495)         # 경로에서 약 17m
    assert res["reroute"] is False and 10 < res["off_route_m"] < 30


def test_off_route_recalculates_from_current_position():
    c, sent = client()
    res = check(c, 35.9910, 129.5495, profile="elderly")   # 경로에서 약 55m
    assert res["reroute"] is True and res["reasons"] == ["off_route"]
    assert res["off_route_m"] > 30 and res["route"]["profile"] == "elderly"
    assert sent[0]["points"][0] == [129.5495, 35.9910]      # 새 경로는 현재 위치에서 출발


def test_new_hazard_ahead_triggers_reroute():
    c, _ = client([ZONE])
    res = check(c, 35.9905, 129.5492)          # 앞쪽 경로(LINE)에 구역이 새로 생긴 상황
    assert res["reroute"] is True and res["reasons"] == ["hazard_on_route"]
    assert res["hazards_ahead"] == ["flood-009"] and res["route"]["geometry"] == DETOUR


def test_hazard_already_passed_is_ignored():
    c, sent = client([ZONE])
    res = check(c, 35.9905, 129.5515)          # 구역(129.5500~129.5510)을 이미 지나옴
    assert res["reroute"] is False and res["hazards_ahead"] == [] and sent == []


def test_unavoidable_hazard_warns_without_reroute():
    c, _ = client([ZONE], detour_exists=False)  # 다른 길이 없어 새 경로도 같은 구역을 지난다
    res = check(c, 35.9905, 129.5492)
    assert res["reroute"] is False and res["reasons"] == [] and res["route"] is None
    assert res["hazards_ahead"] == ["flood-009"]   # 재계산은 안 하지만 경고는 한다


def test_arrived():
    c, sent = client([ZONE])
    res = check(c, 35.99055, 129.55195)
    assert res["arrived"] is True and res["reroute"] is False and sent == []


def test_check_graphhopper_down_gives_503():
    def down(req):
        raise httpx.ConnectError("connection refused", request=req)
    gh = GraphHopperClient(base_url="http://gh", transport=httpx.MockTransport(down))
    app.dependency_overrides[get_service] = lambda: RouteService(client=gh, hazards=Hazards())
    res = TestClient(app).post("/api/route/check", json={
        "current": {"lat": 35.9910, "lon": 129.5495}, "destination": {"lat": B[0], "lon": B[1]}, "geometry": LINE})
    assert res.status_code == 503


# --- 실제 GraphHopper ---

def live_client():
    service = RouteService(client=GraphHopperClient(base_url="http://localhost:8989"), hazards=GeoJsonHazardSource())
    app.dependency_overrides[get_service] = lambda: service
    return TestClient(app)


@pytest.mark.live
def test_live_profiles_differ():
    """같은 출발·도착이라도 유형별로 시간이 다르고, 노약자·휠체어는 성인보다 급경사가 완만하거나 같아야 한다."""
    c = live_client()
    b = {"origin": {"lat": 35.9800, "lon": 129.5600}, "destination": {"lat": 35.9950, "lon": 129.5450}}
    r = {p: c.post("/api/route", json={**b, "profile": p}).json() for p in ("adult", "elderly", "wheelchair")}
    assert r["adult"]["duration_s"] < r["elderly"]["duration_s"]
    assert r["adult"]["duration_s"] < r["wheelchair"]["duration_s"]
    assert r["wheelchair"]["max_slope_pct"] <= r["adult"]["max_slope_pct"]


@pytest.mark.live
def test_live_off_route_check():
    c = live_client()
    route = c.post("/api/route", json={"origin": {"lat": 35.9905, "lon": 129.5560},
                                       "destination": {"lat": 35.9868, "lon": 129.5480}}).json()
    res = c.post("/api/route/check", json={"current": {"lat": 35.9930, "lon": 129.5520},
                                           "destination": {"lat": 35.9868, "lon": 129.5480},
                                           "geometry": route["geometry"]}).json()
    assert res["reroute"] is True and "off_route" in res["reasons"] and res["route"]["distance_m"] > 0
