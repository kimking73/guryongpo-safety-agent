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


def test_elderly_rules_are_sent():
    c, sent = client()
    assert c.post("/api/route", json=body("elderly")).json()["profile"] == "elderly"
    model = sent[0]["custom_model"]
    assert model["priority"] == PROFILE_RULES["elderly"]["priority"]
    assert model["speed"] == PROFILE_RULES["elderly"]["speed"]


def test_only_adult_and_elderly():
    assert set(PROFILE_RULES) == {"adult", "elderly"}
    c, _ = client()
    assert c.post("/api/route", json=body("wheelchair")).status_code == 422   # 휠체어 유형은 없앴다


def test_adult_ignores_slope():
    assert PROFILE_RULES["adult"] == {"priority": [], "speed": []}


def test_elderly_prefers_steps_over_equally_steep_road():
    rules = PROFILE_RULES["elderly"]["priority"]
    # 계단 문장이 맨 앞 if이고 경사 문장은 else_if → 계단에는 경사 벌점이 붙지 않는다
    assert rules[0]["if"] == "road_class == STEPS"
    assert all("else_if" in r and "average_slope" in r["else_if"] for r in rules[1:])
    # 계단(가파름)은 급경사 도로(≥10%)보다 싸다
    assert float(rules[0]["multiply_by"]) > float(rules[1]["multiply_by"])


def test_hazard_penalty_outweighs_every_profile_penalty():
    """위험 구역 벌점이 유형 규칙이 한 구간에 줄 수 있는 가장 센 벌점보다 10배 이상 세야 한다."""
    import math
    from guardian_route.service import AVOID_PRIORITY
    for rules in PROFILE_RULES.values():
        worst = math.prod(float(r["multiply_by"]) for r in rules["priority"]) if rules["priority"] else 1.0
        assert AVOID_PRIORITY * 10 <= worst


def test_profile_rules_combine_with_hazard_avoidance():
    c, sent = client([ZONE])
    res = c.post("/api/route", json=body("elderly")).json()
    safe, base = sent[0]["custom_model"], sent[1]["custom_model"]
    # 회피 경로: 노약자 규칙 + 구역 회피
    assert safe["priority"][:len(PROFILE_RULES["elderly"]["priority"])] == PROFILE_RULES["elderly"]["priority"]
    assert safe["priority"][-1]["if"] == "in_flood_009" and "areas" in safe
    # 비교용 기본 경로: 노약자 규칙은 같고 위험 구역만 뺀다
    assert base["priority"] == PROFILE_RULES["elderly"]["priority"] and "areas" not in base
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
    """같은 출발·도착이라도 노약자가 더 오래 걸리고, 급경사는 성인보다 완만하거나 같아야 한다."""
    c = live_client()
    b = {"origin": {"lat": 35.9800, "lon": 129.5600}, "destination": {"lat": 35.9950, "lon": 129.5450}}
    r = {p: c.post("/api/route", json={**b, "profile": p}).json() for p in ("adult", "elderly")}
    assert r["adult"]["duration_s"] < r["elderly"]["duration_s"]
    assert r["elderly"]["max_slope_pct"] <= r["adult"]["max_slope_pct"]


@pytest.mark.live
def test_live_off_route_check():
    c = live_client()
    route = c.post("/api/route", json={"origin": {"lat": 35.9905, "lon": 129.5560},
                                       "destination": {"lat": 35.9868, "lon": 129.5480}}).json()
    res = c.post("/api/route/check", json={"current": {"lat": 35.9930, "lon": 129.5520},
                                           "destination": {"lat": 35.9868, "lon": 129.5480},
                                           "geometry": route["geometry"]}).json()
    assert res["reroute"] is True and "off_route" in res["reasons"] and res["route"]["distance_m"] > 0


# --- 실제 구룡포 도로망에서 유형별 규칙이 지켜지는지 (live) ---
# 구룡포공원 계단(OSM way 1013424272) 아래 → 위, 성인은 계단 31m를 오른다.
PARK_STEPS = ({"lat": 35.9908295, "lon": 129.5606355}, {"lat": 35.9911047, "lon": 129.5607137})


def _steep_road_m(p, seg):
    """계단이 아닌 도로 중 경사 10% 이상인 구간 길이(m). 노약자 규칙이 피하려는 대상."""
    steps = [(s, e) for s, e, v in p["details"]["road_class"] if v == "steps"]
    total = 0.0
    for s, e, v in p["details"]["average_slope"]:
        if v is None or abs(v) < 10:
            continue
        for i in range(s, e):
            if not any(a <= i < b for a, b in steps):
                total += seg[i]
    return total


def _gh_measure(origin, dest, profile):
    """route 서비스와 같은 custom_model로 GraphHopper를 불러 계단·급경사(≥8%) 거리와 평균 속도를 잰다."""
    import math
    from guardian_route.profiles import PROFILE_RULES
    from guardian_route.service import build_model
    zones = GeoJsonHazardSource().hazards()
    gh = GraphHopperClient(base_url="http://localhost:8989")
    body = {"profile": "foot", "points": [[origin["lon"], origin["lat"]], [dest["lon"], dest["lat"]]],
            "points_encoded": False, "details": ["road_class", "average_slope"]}
    model = build_model(PROFILE_RULES[profile], zones)
    if model:
        body["custom_model"] = model
    p = gh.http.post("/route", json=body).json()["paths"][0]
    co = p["points"]["coordinates"]
    seg = [math.hypot((co[i + 1][0] - co[i][0]) * 111320 * math.cos(math.radians(co[i][1])),
                      (co[i + 1][1] - co[i][1]) * 110540) for i in range(len(co) - 1)]

    def meters(detail, pred):
        return sum(sum(seg[s:e]) for s, e, v in p["details"][detail] if v is not None and pred(v))
    return {"steps": meters("road_class", lambda v: v == "steps"),
            "steep": _steep_road_m(p, seg),
            "kmh": p["distance"] / (p["time"] / 1000) * 3.6}


@pytest.mark.live
def test_live_elderly_takes_park_steps_instead_of_steep_road():
    """구룡포공원 계단: 돌아가는 길도 급경사라서, 노약자는 같은 경사면 계단을 택한다 (사용자 결정)."""
    a, b = PARK_STEPS
    assert _gh_measure(a, b, "adult")["steps"] > 20
    assert _gh_measure(a, b, "elderly")["steps"] > 20


@pytest.mark.live
def test_live_rules_hold_over_random_trips():
    """시가지 무작위 20개 경로: 노약자가 항상 느리고, 계단이 아닌 급경사(≥10%) 도로 합계는 성인보다 적다."""
    import random
    rnd = random.Random(7)
    pt = lambda: {"lat": rnd.uniform(35.975, 36.0), "lon": rnd.uniform(129.54, 129.572)}
    trips = [(pt(), pt()) for _ in range(20)]
    m = {p: [_gh_measure(a, b, p) for a, b in trips] for p in ("adult", "elderly")}
    for a, e in zip(m["adult"], m["elderly"]):
        assert a["kmh"] > e["kmh"]
        assert e["steep"] <= a["steep"] + 1
    assert sum(x["steep"] for x in m["elderly"]) < sum(x["steep"] for x in m["adult"])
