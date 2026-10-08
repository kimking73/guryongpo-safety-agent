"""방재단 다중 방문 경로 /api/route/visits (가짜 GraphHopper, 오프라인) — visits.py"""
import json
import math

import httpx
from fastapi.testclient import TestClient
from shapely.geometry import box

from guardian_route import polyline
from guardian_route.api import app, get_service
from guardian_route.gh import GraphHopperClient
from guardian_route.hazards import Hazard
from guardian_route.service import RouteService
from guardian_route.visits import solve

ORIGIN = {"lat": 35.9900, "lon": 129.5500}


class Hazards:
    def __init__(self, *items):
        self.items = list(items)

    def hazards(self):
        return self.items


def straight(points):
    """가짜 GraphHopper: 점들을 직선으로 이은 경로 (거리 = 직선 거리 합, 1m = 1초)"""
    d = 0.0
    for (lo1, la1), (lo2, la2) in zip(points, points[1:]):
        d += math.hypot((la2 - la1) * 111_000, (lo2 - lo1) * 90_000)
    return {"distance": d, "time": d * 1000, "points": polyline.encode([(la, lo) for lo, la in points])}


def client(hazards=(), blocked_fails=False):
    seen = []

    def handler(req: httpx.Request) -> httpx.Response:
        body = json.loads(req.content)
        seen.append(body)
        hard = any(r.get("multiply_by") == "0" for r in (body.get("custom_model") or {}).get("priority", []))
        if blocked_fails and hard:
            return httpx.Response(400, json={"message": "Connection between locations not found"})
        return httpx.Response(200, json={"paths": [straight(body["points"])]})

    gh = GraphHopperClient(base_url="http://gh", transport=httpx.MockTransport(handler))
    app.dependency_overrides[get_service] = lambda: RouteService(client=gh, hazards=Hazards(*hazards))
    return TestClient(app), seen


def stop(id, lat, lon, tier=4):
    return {"id": id, "lat": lat, "lon": lon, "tier": tier}


# ------------------------------------------------------------------ 순서 (DP)
def test_solve_shortest_open_path():
    # 출발 0 → 집 a(1)·b(2)·c(3)가 한 줄: 0 - a - b - c
    pos = [0, 1, 2, 3]
    cost = [[abs(pos[i] - pos[j]) for j in range(4)] for i in range(4)]
    assert solve(cost, [4, 4, 4], ["a", "b", "c"], False) == [0, 1, 2]


def test_solve_priority_tier_first_even_if_farther():
    # c(도움 요청, tier 1)가 가장 멀어도 먼저, 그다음 같은 단계 a·b는 가까운 순
    pos = [0, 1, 2, 10]
    cost = [[abs(pos[i] - pos[j]) for j in range(4)] for i in range(4)]
    assert solve(cost, [4, 4, 1], ["a", "b", "c"], False) == [0, 1, 2]
    assert solve(cost, [4, 4, 1], ["a", "b", "c"], True) == [2, 1, 0]   # c(10) → b(2) → a(1)


def test_solve_ties_are_deterministic():
    cost = [[0, 5, 5], [5, 0, 1], [5, 1, 0]]
    assert solve(cost, [4, 4], ["b", "a"], False) == solve(cost, [4, 4], ["b", "a"], False) == [1, 0]   # id 'a' 먼저


# ------------------------------------------------------------------ API
def test_visits_returns_both_plans_in_order():
    c, seen = client()
    body = {"origin": ORIGIN, "stops": [stop("far", 35.9990, 129.5500, tier=1), stop("near", 35.9910, 129.5500, tier=4),
                                         stop("mid", 35.9950, 129.5500, tier=4)]}
    res = c.post("/api/route/visits", json=body)
    assert res.status_code == 200
    d = res.json()
    assert [x["id"] for x in d["shortest"]["order"]] == ["near", "mid", "far"]
    assert [x["id"] for x in d["priority"]["order"]] == ["far", "mid", "near"]
    assert [x["seq"] for x in d["priority"]["order"]] == [1, 2, 3]
    assert d["shortest"]["distance_m"] < d["priority"]["distance_m"]
    # 쌍 경로 3×3=9번 + 최종 경로 2번 (모든 점을 한 번에)
    assert len(seen) == 11 and len(seen[-1]["points"]) == 4
    assert d["shortest"]["order"][0]["leg_distance_m"] == round(0.001 * 111_000)


def test_hazards_block_except_zones_with_stops():
    home_zone = Hazard("flood-001", "flood", box(129.5495, 35.9905, 129.5505, 35.9915))   # 'near' 집이 안에 있음
    other = Hazard("flood-002", "flood", box(129.5600, 35.9800, 129.5610, 35.9810))       # 멀리 — 무조건 막음
    c, seen = client([home_zone, other])
    res = c.post("/api/route/visits", json={"origin": ORIGIN, "stops": [stop("near", 35.9910, 129.5500)]})
    assert res.status_code == 200
    rules = {r["if"]: r["multiply_by"] for r in seen[0]["custom_model"]["priority"] if r["if"].startswith("in_")}
    assert rules == {"in_flood_001": "0.001", "in_flood_002": "0"}
    assert res.json()["blocked_zones"] == []


def test_blocked_pair_retries_softly_and_reports():
    wall = Hazard("landslide-009", "landslide", box(129.5490, 35.9940, 129.5510, 35.9945))   # 출발점과 집 사이를 가로막음
    c, seen = client([wall], blocked_fails=True)
    res = c.post("/api/route/visits", json={"origin": ORIGIN, "stops": [stop("a", 35.9990, 129.5500)]})
    assert res.status_code == 200
    assert res.json()["blocked_zones"] == ["landslide-009"]
    assert res.json()["shortest"]["still_inside"] == ["landslide-009"]


def test_stop_count_limits():
    c, _ = client()
    assert c.post("/api/route/visits", json={"origin": ORIGIN, "stops": []}).status_code == 422
    many = [stop(f"s{i}", 35.99 + i * 0.001, 129.55) for i in range(11)]
    assert c.post("/api/route/visits", json={"origin": ORIGIN, "stops": many}).status_code == 422


def test_ten_stops_finish_quickly():
    c, seen = client()
    stops = [stop(f"s{i}", 35.99 + (i % 3) * 0.002, 129.55 + i * 0.001, tier=1 + i % 4) for i in range(10)]
    res = c.post("/api/route/visits", json={"origin": ORIGIN, "stops": stops})
    assert res.status_code == 200 and len(seen) == 10 + 10 * 9 + 2   # 출발→집 10 + 집→집 90 + 최종 2
    assert sorted(x["id"] for x in res.json()["priority"]["order"]) == sorted(s["id"] for s in stops)
    tiers = [x["tier"] for x in res.json()["priority"]["order"]]
    assert tiers == sorted(tiers)
