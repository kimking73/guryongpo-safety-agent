"""경로 안내 서버 /api/route 왕복 (가짜 GraphHopper, 오프라인) + 실제 GraphHopper(live).

위험 구역 회피 테스트는 test_avoid.py.
"""

import json

import httpx
import pytest
from fastapi.testclient import TestClient

from guardian_route.api import app, get_service
from guardian_route.gh import GraphHopperClient
from guardian_route.polyline import decode as decode_polyline
from guardian_route.service import RouteService


class NoHazards:
    """위험 구역 없음. 이 파일은 기본 경로 변환만 본다."""
    def hazards(self):
        return []

# 구룡포항 → 구룡포 실내체육관 부근
BODY = {"origin": {"lat": 35.9905, "lon": 129.5560}, "destination": {"lat": 35.9868, "lon": 129.5480}}
PATH = {"distance": 986.218, "time": 710075, "points": "oktzEe|vuWl@p@BCpAhB", "ascend": 10.2, "descend": 2.0,
        "details": {"average_slope": [[0, 2, 0.0], [2, 5, -7.6], [5, 9, 3.0]]}}


def client(handler) -> tuple[TestClient, list[httpx.Request]]:
    """handler(request) → httpx.Response 로 GraphHopper를 흉내 낸다. 받은 요청을 목록으로 돌려준다."""
    seen: list[httpx.Request] = []

    def record(req: httpx.Request) -> httpx.Response:
        seen.append(req)
        return handler(req)

    gh = GraphHopperClient(base_url="http://gh", transport=httpx.MockTransport(record))
    service = RouteService(client=gh, hazards=NoHazards())
    app.dependency_overrides[get_service] = lambda: service
    return TestClient(app), seen


def ok(req: httpx.Request) -> httpx.Response:
    if req.url.path == "/health":
        return httpx.Response(200, text="OK")
    return httpx.Response(200, json={"paths": [PATH]})


def test_route_converts_graphhopper_response():
    c, seen = client(ok)
    res = c.post("/api/route", json=BODY)
    assert res.status_code == 200
    assert res.json() == {"profile": "adult", "distance_m": 986, "duration_s": 710,
                          "ascend_m": 10, "descend_m": 2, "max_slope_pct": 8,   # 내리막 7.6%도 급경사로 본다
                          "avoided": [], "still_inside": [], "geometry": PATH["points"], "source": "graphhopper"}
    # GraphHopper에는 [lon, lat] 순서, 도보 profile, 인코딩된 polyline으로 요청한다
    sent = json.loads(seen[0].content)
    assert sent["points"] == [[129.5560, 35.9905], [129.5480, 35.9868]]
    assert sent["profile"] == "foot" and sent["points_encoded"] is True
    assert sent["details"] == ["average_slope"]
    assert "custom_model" not in sent and len(seen) == 1     # 성인 + 위험 구역 없음 → 한 번만, 규칙 없이 부른다


def test_profile_defaults_to_adult():
    c, _ = client(ok)
    assert c.post("/api/route", json=BODY).json()["profile"] == "adult"


def test_graphhopper_down_gives_503():
    def down(req):
        raise httpx.ConnectError("connection refused", request=req)
    c, _ = client(down)
    res = c.post("/api/route", json=BODY)
    assert res.status_code == 503
    assert "경로 안내를 일시적으로 사용할 수 없습니다" in res.json()["detail"]


def test_graphhopper_timeout_gives_503():
    def slow(req):
        raise httpx.ReadTimeout("timed out", request=req)
    c, _ = client(slow)
    assert c.post("/api/route", json=BODY).status_code == 503


def test_graphhopper_server_error_gives_503():
    c, _ = client(lambda req: httpx.Response(500, text="boom"))
    assert c.post("/api/route", json=BODY).status_code == 503


def test_out_of_area_gives_404_with_reason():
    msg = "Point 1 is out of bounds: 35.9868,129.7"
    c, _ = client(lambda req: httpx.Response(400, json={"message": msg}))
    res = c.post("/api/route", json=BODY)
    assert res.status_code == 404
    assert "경로를 찾지 못했습니다" in res.json()["detail"] and msg in res.json()["detail"]


@pytest.mark.parametrize("bad", [
    {"origin": {"lat": 95, "lon": 129.5}, "destination": BODY["destination"]},   # 위도 범위 밖
    {"origin": BODY["origin"]},                                                   # 도착지 없음
    {**BODY, "profile": "bicycle"},                                               # 없는 profile
])
def test_invalid_request_gives_422(bad):
    c, _ = client(ok)
    assert c.post("/api/route", json=bad).status_code == 422


def test_health_reports_graphhopper_state():
    c, _ = client(ok)
    assert c.get("/api/route/health").json() == {"status": "ok", "graphhopper": "ok"}

    def down(req):
        raise httpx.ConnectError("connection refused", request=req)
    c, _ = client(down)
    res = c.get("/api/route/health")
    assert res.status_code == 200
    assert res.json() == {"status": "ok", "graphhopper": "error"}


@pytest.mark.live
def test_live_route_in_guryongpo():
    """실제 graphhopper 컨테이너(localhost:8989). 구룡포 안 두 점 사이에 도로를 따라가는 경로가 나와야 한다."""
    service = RouteService(client=GraphHopperClient(base_url="http://localhost:8989"), hazards=NoHazards())
    app.dependency_overrides[get_service] = lambda: service
    res = TestClient(app).post("/api/route", json=BODY).json()
    assert 500 < res["distance_m"] < 3000
    pts = decode_polyline(res["geometry"])
    assert len(pts) > 5                                             # 직선이 아니라 도로를 따라 꺾인다
    assert abs(pts[0][0] - 35.9905) < 0.002 and abs(pts[-1][1] - 129.5480) < 0.002
