"""위치·경로 agent: 갈 만한 대피소 고르기, 실제 경로 근거, 템플릿 대체, 환각 검증 (DB·LLM·경로 서버 없이 실행)."""

import json

import httpx

from guardian_ai import graph as G
from guardian_ai import location as L
from guardian_ai.service import ChatRequest, ChatService
from guardian_ai.state import Location, Specialist, UserProfile
from guardian_ai.tools import get_safe_shelters

HERE = Location(lat=35.9907, lon=129.5526, label="현재 위치")


def shelter(i, name, dist, in_hazard=None, underground=False, flood_active=True, indoor=False):
    return {"id": i, "name": name, "shelter_types": ["civil_defense" if underground else "tsunami"], "address": "구룡포읍",
            "is_indoor": indoor or underground, "lat": 35.99 + i / 1000, "lon": 129.55, "distance_m": float(dist),
            "in_hazard": in_hazard, "underground": underground, "flood_active": flood_active}


def flood_db(sql, params):
    """침수 중: 가장 가까운 두 곳은 위험 영역 안·지하, 세 번째가 갈 만한 곳."""
    if "FROM shelters" in sql:
        return [shelter(1, "구룡포 초등학교 앞", 120, in_hazard="침수 경보"),
                shelter(2, "여의주타워 지하주차장 1층", 230, underground=True),
                shelter(3, "충혼탑 앞", 700)]
    return []


def all_unsafe_db(sql, params):
    if "FROM shelters" in sql:
        return [shelter(1, "구룡포 초등학교 앞", 120, in_hazard="침수 경보")]
    return []


def route_server(sent=None, status=200, body=None):
    def handler(req):
        if sent is not None:
            sent.append(json.loads(req.content))
        return httpx.Response(status, json=body or {
            "profile": "elderly", "distance_m": 1024, "duration_s": 984, "ascend_m": 3, "descend_m": 2,
            "max_slope_pct": 9, "avoided": ["flood-12"], "still_inside": [], "geometry": "abc", "source": "graphhopper",
            "hazards_ok": True})
    return httpx.Client(base_url="http://route", transport=httpx.MockTransport(handler))


def state(question="어디로 대피해야 해?", age=72):
    return {"mode": "chat", "question": question, "current_location": HERE,
            "user": UserProfile(user_id="u1", age=age)}


def test_tool_marks_hazard_and_underground_shelters():
    items = get_safe_shelters(35.99, 129.55, fetch=flood_db)["items"]
    assert [(i["name"], i["safe"]) for i in items] == [
        ("구룡포 초등학교 앞", False), ("여의주타워 지하주차장 1층", False), ("충혼탑 앞", True)]
    assert items[0]["excluded_reason"] == "위험 영역 안(침수 경보)"
    assert items[1]["excluded_reason"] == "침수 중 지하 시설"


def test_underground_is_fine_when_no_flood():
    def dry_db(sql, params):
        return [shelter(2, "여의주타워 지하주차장 1층", 230, underground=True, flood_active=False)] if "FROM shelters" in sql else []
    assert get_safe_shelters(35.99, 129.55, fetch=dry_db)["items"][0]["safe"]


def test_picks_nearest_safe_shelter_and_requests_elderly_route():
    sent = []
    d = L.collect(state(), fetch=flood_db, route_client=route_server(sent))
    assert d.chosen["name"] == "충혼탑 앞"
    assert sent[0]["profile"] == "elderly" and sent[0]["destination"] == {"lat": 35.993, "lon": 129.55}
    ev = {e.key: e.value for e in d.evidence}
    assert ev["안내 대피소"] == "충혼탑 앞"
    assert ev["경로 거리"] == 1024 and ev["도보 소요 시간"] == 17
    assert ev["경로가 피한 위험 영역 수"] == 1
    assert ev["제외한 더 가까운 대피소: 구룡포 초등학교 앞"] == "위험 영역 안(침수 경보)"


def test_adult_when_young():
    sent = []
    L.collect(state(age=30), fetch=flood_db, route_client=route_server(sent))
    assert sent[0]["profile"] == "adult"


def test_no_safe_shelter_warns_and_still_guides():
    d = L.collect(state(), fetch=all_unsafe_db, route_client=route_server())
    assert d.chosen["name"] == "구룡포 초등학교 앞"
    assert "가장 가까운 곳을 안내" in L.template_summary(d)


def test_route_server_down_falls_back_to_straight_distance():
    d = L.collect(state(), fetch=flood_db, route_client=route_server(status=503, body={"detail": "엔진 장애"}))
    assert any("경로 안내" in m for m in d.unavailable)
    assert "직선거리는 700m" in L.template_summary(d)


def test_template_used_when_writer_fails():
    def broken(*a):
        raise TimeoutError
    out = L.make_location_route_agent(writer=broken, fetch=flood_db, route_client=route_server())(state())
    r = out["specialist_results"][0]
    assert r.agent == Specialist.LOCATION_ROUTE and "충혼탑 앞" in r.summary and "1024m" in r.summary
    assert r.route["distance_m"] == 1024 and "geometry" not in r.route


def service_with(writer):
    return ChatService(classifier=G.keyword_classify, overrides={
        Specialist.LOCATION_ROUTE.value: L.make_location_route_agent(writer=writer, fetch=flood_db, route_client=route_server())})


def test_wrong_distance_is_caught_and_rewritten():
    answers = iter(["충혼탑 앞까지 300m, 도보 3분입니다.", "충혼탑 앞까지 1024m, 도보 약 17분입니다."])
    res = service_with(lambda *a: next(answers)).chat(ChatRequest(
        user_id="u1", question="대피소까지 어떻게 가?", current_location=HERE, profile=UserProfile(user_id="u1", age=72)))
    assert "1024m" in res.answer and "300m" not in res.answer and not res.used_fallback


def test_stub_agents_never_leak_stub_text():
    """구현 전 agent만 고른 질문은 'stub' 대신 준비 중 안내."""
    res = ChatService(classifier=G.keyword_classify).chat(ChatRequest(user_id="u1", question="태풍 오면 어떡해?"))
    assert "stub" not in res.answer and res.answer == G.NOT_READY
