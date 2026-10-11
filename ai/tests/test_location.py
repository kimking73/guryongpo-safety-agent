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
from guardian_ai.flood import pick_location  # noqa: E402

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


def test_route_stays_in_response_when_check_limit_is_exceeded():
    def always_wrong(*a):
        return "충혼탑 앞까지 999m입니다."
    svc = ChatService(classifier=G.keyword_classify, overrides={
        Specialist.LOCATION_ROUTE.value: L.make_location_route_agent(writer=always_wrong, fetch=flood_db, route_client=route_server())})
    res = svc.chat(ChatRequest(user_id="u1", question="어디로 대피해야 해?", current_location=HERE))
    assert res.used_fallback and "999m" in res.answer and res.route is not None


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


# --- 질문에서 말한 장소를 기준 위치로 (2026-10-12) ---------------------------------

def _clf(**kw):
    parsed = Classification(agents=[Specialist.RAIN_FLOOD], reason="침수", **kw)
    return OpenAIClassifier(client=SimpleNamespace(responses=SimpleNamespace(
        parse=lambda **k: SimpleNamespace(output_parsed=parsed, output_text="", usage=None))), model="t")


def test_manager_turns_place_in_question_into_reference_location():
    """ "우리 가게 침수됐어?" → 분류기 place '가게' → locate가 찾은 좌표가 이번 질문의 기준 위치"""
    shop = Location(lat=35.9894, lon=129.5534, label="가게")
    asked = []
    locate = lambda q, u: asked.append(q) or shop  # noqa: E731
    here = Location(lat=35.98643, lon=129.54509)
    out = G.make_manager(_clf(place="가게"), locate=locate)(
        {"mode": "chat", "question": "우리 가게 침수됐어?", "user": UserProfile(user_id="u1"), "current_location": here})
    assert asked == ["가게"] and out["reference_location"] == shop and out["reference_query"] == "가게"
    loc, known = pick_location({**out, "current_location": here})
    assert (loc.lat, loc.label, known) == (35.9894, "가게", True)          # 현재 위치보다 먼저
    # 다음 질문에서 장소를 말하지 않으면 다시 현재 위치 기준
    nxt = G.make_manager(_clf(), locate=locate)({**out, "mode": "chat", "question": "지금 여기 바람은 어때?", "current_location": here})
    assert nxt["reference_location"] is None and nxt["reference_query"] is None
    assert pick_location({**nxt, "current_location": here})[0].label == "현재 위치"


def test_reference_place_not_found_keeps_current_location_and_says_so():
    out = G.make_manager(_clf(place="우주상사"), locate=lambda q, u: None)(
        {"mode": "chat", "question": "우주상사 침수됐어?", "user": UserProfile(user_id="u1")})
    assert out["reference_location"] is None and out["reference_query"] == "우주상사"
    loc, known = pick_location({**out, "current_location": Location(lat=35.99, lon=129.55)})
    assert loc.lat == 35.99 and known and "'우주상사' 위치는 찾지 못함" in loc.label
    loc, known = pick_location(out)                                        # 위치 정보도 없으면 읍 중심 + 두 사실 모두
    assert not known and "위치 정보 없음" in loc.label and "우주상사" in loc.label


def test_reference_place_is_ignored_without_locate_or_when_locate_fails():
    q = {"mode": "chat", "question": "우리 가게 침수됐어?", "user": UserProfile(user_id="u1")}
    assert G.make_manager(_clf(place="가게"))(q)["reference_query"] is None            # 기본 그래프(테스트)는 쓰지 않는다

    def boom(query, u):
        raise RuntimeError("장소 검색 장애")
    out = G.make_manager(_clf(place="가게"), locate=boom)(q)                            # 장애여도 답은 나간다
    assert out["reference_location"] is None and out["selected_agents"] == [Specialist.RAIN_FLOOD]


def test_said_place_is_the_route_origin_and_reference_evidence():
    """ "호미로 152에 있는데 가까운 대피소 알려줘" → 그 주소에서 출발하는 경로, 근거의 기준 위치도 그 주소"""
    sent = []
    ref = Location(lat=35.9871, lon=129.5522, label="호미로 152")
    d = L.collect({**state(), "reference_query": "호미로 152", "reference_location": ref},
                  fetch=flood_db, route_client=route_server(sent))
    assert sent[0]["origin"] == {"lat": 35.9871, "lon": 129.5522}
    assert {e.key: e.value for e in d.evidence}["기준 위치"] == "호미로 152"


def test_locate_reference_uses_registered_place_name(monkeypatch):
    from guardian_ai import service as SV
    from guardian_ai import tools as T
    monkeypatch.delenv("KAKAO_REST_KEY", raising=False)
    monkeypatch.setattr(T, "default_fetch", lambda: (lambda sql, params: []), raising=False)
    u = UserProfile(user_id="u1", frequent_places=[Location(lat=35.9894, lon=129.5534, label="가게")])
    monkeypatch.setattr(T, "find_place", lambda q, user=None, **kw: (
        {"available": True, "name": "가게", "lat": 35.9894, "lon": 129.5534, "kind": "place", "source": "user"}
        if q.replace(" ", "") == "우리가게" else {"available": False, "reason": "없음"}))
    assert SV.locate_reference("우리 가게", u) == Location(lat=35.9894, lon=129.5534, label="가게")
    assert SV.locate_reference("모르는 곳", u) is None


def test_coordinates_in_question_set_the_reference_location():
    """ "35.9905, 129.5560에서 가까운 대피소 알려줘" → 그 좌표가 기준·출발지 (2026-10-12). 장소 검색을 거치지 않는다"""
    assert (G.coords_in("35.9905, 129.5560에서 출발").lat, G.coords_in("35.9905, 129.5560에서 출발").lon) == (35.9905, 129.556)
    assert G.coords_in("위도 35.9905 경도 129.5560").label == "위도 35.9905, 경도 129.556"
    assert G.coords_in("129.5560 / 35.9905").lat == 35.9905                     # 경도를 먼저 써도
    assert G.coords_in("평균 풍속 16.5m/s, 순간 24.03m/s 인데 괜찮아?") is None    # 좌표가 아닌 수
    assert G.coords_in("비 12.55mm 왔어") is None and G.coords_in(None) is None

    def never(q, u):
        raise AssertionError("좌표는 장소 검색을 하지 않는다")
    out = G.make_manager(_clf(), locate=never)(
        {"mode": "chat", "question": "35.9905, 129.5560에서 가까운 대피소 알려줘", "user": UserProfile(user_id="u1"),
         "current_location": Location(lat=35.98643, lon=129.54509)})
    assert (out["reference_location"].lat, out["reference_location"].lon) == (35.9905, 129.556)
    sent = []
    L.collect({**state(), **out}, fetch=flood_db, route_client=route_server(sent))
    assert sent[0]["origin"] == {"lat": 35.9905, "lon": 129.556}
    # 기본 그래프(locate 없음)·분류기가 이전 대화에서 가져온 좌표도 같다
    out = G.make_manager(_clf(place="35.9905, 129.5560"))({"mode": "chat", "question": "거기 침수됐어?", "user": UserProfile(user_id="u1")})
    assert out["reference_location"].lat == 35.9905 and out["reference_query"] == "위도 35.9905, 경도 129.556"


def test_typed_coordinates_stay_as_origin_until_cleared():
    """좌표로 정한 출발지는 이 대화에서 계속 쓴다 — 다음 질문에 좌표가 없어도. "현재 위치로"로 푼다"""
    here = Location(lat=35.98643, lon=129.54509)
    base = {"mode": "chat", "user": UserProfile(user_id="u1"), "current_location": here}
    none = OpenAIClassifier(client=SimpleNamespace(responses=SimpleNamespace(parse=lambda **k: SimpleNamespace(
        output_parsed=Classification(agents=[], reason="질문 없음"), output_text="", usage=None))), model="t")
    s1 = {**base, **G.make_manager(none)({**base, "question": "출발지는 35.9905, 129.5560 야."})}
    assert s1["origin_changed"] == "set" and s1["pinned_origin"].lat == 35.9905
    assert "위도 35.9905, 경도 129.556" in G.direct_reply(s1)["final_answer"]
    s2 = {**s1, **G.make_manager(_clf())({**s1, "question": "가까운 대피소 알려줘"})}
    assert s2["reference_location"] is None and s2["origin_changed"] is None
    loc, known = pick_location(s2)
    assert (loc.lat, loc.label, known) == (35.9905, "위도 35.9905, 경도 129.556", True)
    # 이번 질문에서 말한 장소가 있으면 그 질문만 그곳 기준
    shop = Location(lat=35.9894, lon=129.5534, label="가게")
    s3 = {**s2, **G.make_manager(_clf(place="가게"), locate=lambda q, u: shop)({**s2, "question": "우리 가게 침수됐어?"})}
    assert pick_location(s3)[0].label == "가게" and s3["pinned_origin"].lat == 35.9905
    # 분류기가 경로 agent를 골라도 푸는 말만 있으면 확인 문장으로 끝낸다
    route_clf = OpenAIClassifier(client=SimpleNamespace(responses=SimpleNamespace(parse=lambda **k: SimpleNamespace(
        output_parsed=Classification(agents=[Specialist.LOCATION_ROUTE], reason="안내"), output_text="", usage=None))), model="t")
    s4 = {**s3, **G.make_manager(route_clf)({**s3, "question": "이제 현재 위치로 안내해 줘"})}
    assert s4["selected_agents"] == []
    assert s4["pinned_origin"] is None and G.direct_reply(s4)["final_answer"] == G.ORIGIN_CLEARED_REPLY
    assert pick_location(s4)[0].label == "현재 위치"
