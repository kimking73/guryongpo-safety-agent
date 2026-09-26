"""request_route tool → route 서비스 호출 (가짜 route 서버). B7."""

import json

import httpx

from guardian_ai.tools import request_route

ROUTE = {"profile": "elderly", "distance_m": 1324, "duration_s": 1270, "ascend_m": 12, "descend_m": 4,
         "max_slope_pct": 6, "avoided": ["flood-001"], "still_inside": [], "geometry": "abc", "source": "graphhopper"}


def fake(handler) -> httpx.Client:
    return httpx.Client(base_url="http://route", transport=httpx.MockTransport(handler))


def test_calls_route_service_and_returns_route():
    sent = []

    def ok(req):
        sent.append((req.url.path, json.loads(req.content)))
        return httpx.Response(200, json=ROUTE)

    res = request_route((35.9905, 129.556), (35.9868, 129.548), "elderly", client=fake(ok))
    assert res == {**ROUTE, "available": True}
    assert sent == [("/api/route", {"origin": {"lat": 35.9905, "lon": 129.556},
                                     "destination": {"lat": 35.9868, "lon": 129.548},
                                     "profile": "elderly", "avoid_manholes": True})]


def test_route_server_down_is_unavailable_not_exception():
    def down(req):
        raise httpx.ConnectError("refused", request=req)
    res = request_route((35.99, 129.55), (35.98, 129.54), client=fake(down))
    assert res["available"] is False and "연결할 수 없습니다" in res["reason"]


def test_route_not_found_passes_reason():
    detail = "구룡포 도로망에서 경로를 찾지 못했습니다. (out of bounds)"
    res = request_route((35.99, 129.55), (35.98, 129.70),
                        client=fake(lambda req: httpx.Response(404, json={"detail": detail})))
    assert res == {"available": False, "reason": detail, "source": "route"}


def test_route_profile_from_user():
    from guardian_ai.state import Mobility, UserProfile
    from guardian_ai.tools import route_profile

    assert route_profile(UserProfile(user_id="u")) == "adult"
    assert route_profile(UserProfile(user_id="u", age=40)) == "adult"
    assert route_profile(UserProfile(user_id="u", age=65)) == "elderly"
    assert route_profile(UserProfile(user_id="u", age=30, walking_impaired=True)) == "elderly"
    assert route_profile(UserProfile(user_id="u", has_dependents=True)) == "elderly"
    assert route_profile(UserProfile(user_id="u", age=80, mobility=Mobility.WHEELCHAIR)) == "wheelchair"
