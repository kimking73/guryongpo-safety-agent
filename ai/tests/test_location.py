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


LAND_ROUTE = {"profile": "elderly", "distance_m": 1024, "duration_s": 984, "ascend_m": 3, "descend_m": 2,
              "max_slope_pct": 9, "avoided": ["flood-12"], "still_inside": [], "geometry": "abc", "source": "graphhopper",
              "hazards_ok": True}


def route_server(sent=None, status=200, body=None, sea=None):
    """가짜 경로 서버. /api/route/sea는 육지(at_sea=False) + 같은 경로, sea를 주면 그 응답. sent에는 요청 본문"""
    def handler(req):
        if sent is not None:
            sent.append(json.loads(req.content))
        if status != 200:
            return httpx.Response(status, json=body)
        if req.url.path == "/api/route/sea":
            return httpx.Response(200, json=sea or {"at_sea": False, "land_route": body or LAND_ROUTE})
        return httpx.Response(200, json=body or LAND_ROUTE)
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
    assert r.route["distance_m"] == 1024 and r.route["geometry"] == "abc"          # 앱이 지도에 그린다
    assert r.route["destination"] == {"name": "충혼탑 앞", "lat": 35.993, "lon": 129.55, "kind": "shelter"}


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


# --- 목적지 지정 (등록 장소 → DB 시설 → 카카오) ---------------------------------

from types import SimpleNamespace  # noqa: E402

from guardian_ai.llm import Classification, OpenAIClassifier  # noqa: E402
from guardian_ai.tools import find_place  # noqa: E402

HOME = Location(lat=35.9935, lon=129.5498, label="집")
WORK = Location(lat=35.9879, lon=129.5548, label="직장")


def kakao(docs=None, status=200, seen=None):
    def handler(req):
        if seen is not None:
            seen.append(req)
        return httpx.Response(status, json={"documents": docs if docs is not None else [
            {"place_name": "구룡포항", "x": "129.5560", "y": "35.9905", "road_address_name": "경북 포항시 남구 구룡포읍 호미로"}]})
    return httpx.Client(base_url="http://kakao", transport=httpx.MockTransport(handler))


def place_db(sql, params):
    """시설 이름 검색: '충혼탑'만 대피소로 있음. 위험 영역: 구룡포항 좌표만 침수 경보 안."""
    if "ILIKE" in sql:
        return [{"name": "충혼탑 앞", "lat": 35.99144, "lon": 129.56073, "kind": "shelter"}] if "충혼탑" in params["q"] else []
    if "string_agg(DISTINCT ra.label" in sql and "FROM shelters" not in sql:
        return [{"labels": "침수 경보" if abs(params["lat"] - 35.9905) < 1e-6 else None}]
    return flood_db(sql, params)


def user(**kw):
    return UserProfile(user_id="u1", age=40, home=HOME, frequent_places=[WORK], **kw)


def test_find_place_prefers_registered_places():
    assert find_place("집", user(), fetch=place_db)["kind"] == "home"
    w = find_place("회사", user(), fetch=place_db)
    assert (w["kind"], w["name"], w["source"]) == ("work", "직장", "user")


def test_find_place_home_without_registration_says_so():
    r = find_place("집", UserProfile(user_id="u1"), fetch=place_db)
    assert not r["available"] and "등록" in r["reason"]


def test_find_place_db_facility_before_kakao():
    seen = []
    r = find_place("충혼탑", user(), fetch=place_db, client=kakao(seen=seen))
    assert (r["name"], r["source"]) == ("충혼탑 앞", "db") and seen == []


def test_find_place_kakao_uses_fixed_center_not_user_location():
    seen = []
    r = find_place("구룡포항", user(), fetch=place_db, client=kakao(seen=seen))
    assert (r["name"], r["source"], r["kind"]) == ("구룡포항", "kakao", "place") and r["address"]
    assert seen[0].url.params["y"] == "35.9858" and seen[0].url.params["x"] == "129.5481"


def test_find_place_kakao_outside_route_area_and_errors():
    far = kakao(docs=[{"place_name": "서울역", "x": "126.97", "y": "37.55"}])
    assert find_place("서울역", user(), fetch=place_db, client=far)["out_of_area"]
    assert not find_place("구룡포항", user(), fetch=place_db, client=kakao(status=500))["available"]
    assert not find_place("없는곳", user(), fetch=place_db, client=kakao(docs=[]))["available"]


def test_find_place_without_kakao_key_skips_search(monkeypatch):
    monkeypatch.delenv("KAKAO_REST_KEY", raising=False)
    r = find_place("구룡포항", user(), fetch=place_db)
    assert not r["available"] and "키 없음" in r["reason"]


def dest_state(dest, question="거기까지 어떻게 가?", **kw):
    return {**state(question=question, age=40), "destination_query": dest, "user": user(**kw)}


def test_routes_to_destination_and_returns_it_for_the_map():
    sent = []
    out = L.make_location_route_agent(fetch=place_db, route_client=route_server(sent), place_client=kakao())(
        dest_state("직장"))["specialist_results"][0]
    assert sent[0]["destination"] == {"lat": WORK.lat, "lon": WORK.lon}
    assert out.route["destination"]["kind"] == "work" and "직장까지 안내" in out.summary


def test_destination_in_hazard_area_recommends_shelter_instead():
    d = L.collect(dest_state("구룡포항"), fetch=place_db, route_client=route_server(), place_client=kakao())
    ev = {e.key: e.value for e in d.evidence}
    assert ev["목적지"] == "구룡포항" and ev["목적지를 찾은 곳"] == "카카오 장소 검색"
    assert "위험 영역 안(침수 경보)" in ev["목적지 위험"]
    assert ev["대신 갈 수 있는 가까운 대피소"] == "충혼탑 앞"
    assert ev["경로 도착지"] == "충혼탑 앞"              # 위험한 목적지로는 길을 그리지 않는다
    assert L.route_info(d)["destination"] == {"name": "충혼탑 앞", "lat": 35.993, "lon": 129.55, "kind": "shelter"}
    assert "가지 않는 것이 좋습니다" in L.template_summary(d) and "충혼탑 앞까지" in L.template_summary(d)


def test_unknown_destination_falls_back_to_nearest_safe_shelter():
    d = L.collect(dest_state("없는곳"), fetch=place_db, route_client=route_server(), place_client=kakao(docs=[]))
    assert d.place is None and d.chosen["name"] == "충혼탑 앞"
    assert "찾지 못함" in {e.key: e.value for e in d.evidence}["요청한 목적지"]
    assert L.route_info(d)["destination"]["kind"] == "shelter"


# --- 관리자: 목적지·보행 불편 뽑기 ------------------------------------------------

def test_keyword_extraction_when_llm_is_unavailable():
    assert G.keyword_destination("구룡포항까지 어떻게 가?") == "구룡포항"
    assert G.keyword_destination("대피소로 가야 해?") is None
    assert G.keyword_mobility_limited("무릎이 안 좋은데 대피소 어디야?")


def test_manager_takes_destination_and_mobility_from_llm_classifier():
    parsed = Classification(agents=[Specialist.LOCATION_ROUTE], reason="경로", destination="구룡포항", mobility_limited=True)
    clf = OpenAIClassifier(client=SimpleNamespace(responses=SimpleNamespace(
        parse=lambda **kw: SimpleNamespace(output_parsed=parsed, output_text="", usage=None))), model="t")
    out = G.make_manager(clf)({"mode": "chat", "question": "다리가 불편한데 항구 가는 길", "user": UserProfile(user_id="u1")})
    assert out["destination_query"] == "구룡포항"
    assert out["user"].walking_impaired is True


def test_generic_shelter_word_from_classifier_is_not_a_destination():
    """분류기가 "대피소"를 목적지로 뽑아도 장소 검색을 하지 않는다 — 가장 가까운 안전한 대피소로 (2026-10-07 시연 질문)"""
    parsed = Classification(agents=[Specialist.LOCATION_ROUTE], reason="경로", destination="대피소", mobility_limited=True)
    clf = OpenAIClassifier(client=SimpleNamespace(responses=SimpleNamespace(
        parse=lambda **kw: SimpleNamespace(output_parsed=parsed, output_text="", usage=None))), model="t")
    out = G.make_manager(clf)({"mode": "chat", "question": "다리가 불편한데 대피소까지 얼마나 걸려?", "user": UserProfile(user_id="u1")})
    assert out["destination_query"] is None


def test_mobility_from_question_does_not_override_app_value():
    out = G.manager({"mode": "chat", "question": "무릎이 아파요 어디로 대피해?",
                     "user": UserProfile(user_id="u1", walking_impaired=False)})
    assert "user" not in out


def test_same_question_mobility_gives_elderly_route():
    """기억 저장(답변 뒤) 전에도, 이번 질문에서 말한 보행 불편으로 노약자 경로."""
    sent = []
    svc = ChatService(classifier=G.keyword_classify, overrides={
        Specialist.LOCATION_ROUTE.value: L.make_location_route_agent(fetch=flood_db, route_client=route_server(sent))})
    svc.chat(ChatRequest(user_id="u1", question="무릎이 안 좋은데 어디로 대피해야 해?", current_location=HERE,
                         profile=UserProfile(user_id="u1", age=40)))
    assert sent[0]["profile"] == "elderly"


# --- 채팅 응답에 경로 -----------------------------------------------------------

def test_chat_response_carries_route_for_the_app():
    svc = ChatService(classifier=G.keyword_classify, overrides={
        Specialist.LOCATION_ROUTE.value: L.make_location_route_agent(fetch=flood_db, route_client=route_server())})
    res = svc.chat(ChatRequest(user_id="u1", question="어디로 대피해야 해?", current_location=HERE))
    assert res.route is not None and res.route.geometry == "abc"
    assert res.route.destination.name == "충혼탑 앞" and res.route.distance_m == 1024


def test_no_route_in_response_when_answer_fell_back():
    def always_wrong(*a):
        return "충혼탑 앞까지 999m입니다."
    svc = ChatService(classifier=G.keyword_classify, overrides={
        Specialist.LOCATION_ROUTE.value: L.make_location_route_agent(writer=always_wrong, fetch=flood_db, route_client=route_server())})
    res = svc.chat(ChatRequest(user_id="u1", question="어디로 대피해야 해?", current_location=HERE))
    assert res.used_fallback and res.route is None


def test_location_answer_drops_sentences_deferring_risk_topics():
    """위치·경로 답의 "침수 위험 여부는 확인할 수 없습니다"는 침수 agent 답과 모순 → 지운다. 경로 사실 문장은 남긴다 (결함 #8)"""
    from guardian_ai.flood import RISK_TOPICS, strip_deferrals
    text = ("현재 위치의 침수 위험 여부는 여기서 안내하지 않습니다. 구룡포중학교 앞까지 1187m, 도보 15분입니다. "
            "다른 길이 없어 위험 영역 1곳을 지납니다. 바람과 파도 상황은 확인할 수 없습니다.")
    assert strip_deferrals(text, RISK_TOPICS) == "구룡포중학교 앞까지 1187m, 도보 15분입니다. 다른 길이 없어 위험 영역 1곳을 지납니다."


def test_risk_answer_drops_sentences_deferring_evacuation_place():
    from guardian_ai.flood import PLACE_TOPICS, strip_deferrals
    text = "강풍 위험 단계는 주의입니다. 배 출항 가능 여부는 확인할 수 없습니다. 어디로 대피할지는 위치·경로 안내에서 확인해 주세요."
    assert strip_deferrals(text, PLACE_TOPICS) == "강풍 위험 단계는 주의입니다. 배 출항 가능 여부는 확인할 수 없습니다."
    assert strip_deferrals("대피소 정보를 확인할 수 없습니다.", PLACE_TOPICS) == "대피소 정보를 확인할 수 없습니다."  # 다 지워지면 원문
