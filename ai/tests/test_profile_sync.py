"""대화 내용 → 서버 프로필 (profile_sync.py) + 서버 프로필 읽기 (tools.get_user_profile) + /api/chat 로그인 규칙 (2026-10-08)."""

from datetime import datetime

import httpx
import pytest
from fastapi.testclient import TestClient

from guardian_ai import graph as G
from guardian_ai import profile_sync as P
from guardian_ai.api import _signed_in, app, get_service
from guardian_ai.llm import MemoryFact
from guardian_ai.service import ChatRequest, ChatService, _place_queries


def fact(field, value):
    # 추출기가 더 내지 않는 칸(보행·동반자)도 들어왔다고 치고 무시되는지 보려고 검사 없이 만든다
    return MemoryFact.model_construct(field=field, value=value, quote=value)


@pytest.mark.parametrize("field, value, expect", [
    ("age", "72", {"birth_year": 1954}),
    # 보행 능력·보호가 필요한 동반자는 프로필에 쓰지 않는다 (2026-10-09)
    ("walking_impaired", "true", {}),
    ("has_dependents", "true", {}),
    ("hearing_impaired", "true", {"hearing_impaired": True}),
    ("mobility", "public_transport", {"mobility": "public_transit"}),
    ("mobility", "helicopter", {}),
    ("occupation", "어선을 몰아요", {"occupation": "fisher", "owns_vessel": True}),
    ("occupation", "카페 사장", {"occupation": "merchant", "owns_vessel": False}),
    ("occupation", "프로그래머", {"occupation": "프로그래머", "owns_vessel": False}),
    ("age", "몰라요", {}),
])
def test_to_patch(field, value, expect):
    assert P.to_patch([fact(field, value)], today=datetime(2026, 10, 8)) == expect


def fake_api(seen, places=()):
    def handle(request: httpx.Request):
        seen.append((request.method, request.url.path, request.headers.get("authorization"),
                     request.content and __import__("json").loads(request.content)))
        if request.method == "POST" and request.url.path == "/api/v1/user":
            return httpx.Response(200, json={"places": list(places)})
        return httpx.Response(201, json={"id": "new"})
    return httpx.Client(base_url="http://api", transport=httpx.MockTransport(handle))


FOUND = {"구룡포시장": {"lat": 35.987, "lon": 129.553, "address": "경북 포항시 남구 구룡포읍 구룡포길 1"},
         "호미로 152": {"lat": 35.99, "lon": 129.55, "address": "호미로 152"}}


def test_writer_updates_profile_and_adds_places_with_users_token():
    seen = []
    w = P.ProfileWriter(client=fake_api(seen), locate=FOUND.get)
    done = w.apply("tok", [fact("age", "70"), fact("home_address", "구룡포시장"), fact("frequent_place", "어딘가 모를 곳")],
                   today=datetime(2026, 10, 8))
    assert seen[0][:3] == ("POST", "/api/v1/user", "Bearer tok") and seen[0][3] == {"birth_year": 1956}
    assert seen[1][:2] == ("POST", "/api/v1/user/places")
    assert seen[1][3]["place_type"] == "home" and seen[1][3]["location"] == {"lat": 35.987, "lng": 129.553}
    assert done["places"] == ["집(구룡포시장)"]                       # 좌표 못 찾은 곳은 넣지 않음
    # 반영한 것만 수집 기록에 (앱 프로필 화면 'AI가 대화에서 수집한 정보')
    assert seen[2][:2] == ("POST", "/api/v1/user/profile-updates") and len(seen) == 3
    assert seen[2][3]["items"] == [{"field": "age", "label": "나이", "value": "70세", "quote": "70"},
                                   {"field": "home_address", "label": "집 주소", "value": "구룡포시장", "quote": "구룡포시장"}]
    assert done["recorded"] == 2


def test_writer_moves_existing_home_and_skips_known_place():
    seen = []
    places = [{"id": "h1", "place_type": "home", "label": "우리집"}, {"id": "p1", "place_type": "frequent", "label": "구룡포시장"}]
    w = P.ProfileWriter(client=fake_api(seen, places), locate=FOUND.get)
    w.apply("tok", [fact("home_address", "호미로 152"), fact("frequent_place", "구룡포시장")])
    assert [(m, p) for m, p, *_ in seen] == [("POST", "/api/v1/user"), ("PATCH", "/api/v1/user/places/h1"),
                                             ("POST", "/api/v1/user/profile-updates")]
    assert [i["field"] for i in seen[2][3]["items"]] == ["home_address"]      # 이미 있던 자주 가는 곳은 기록 안 함
    assert seen[1][3]["label"] == "우리집"                            # 집 이름은 사용자가 붙인 그대로


def test_writer_does_nothing_without_facts():
    seen = []
    assert P.ProfileWriter(client=fake_api(seen)).apply("tok", []) == {"profile": {}, "places": [], "recorded": 0}
    assert seen == []


def test_place_queries_strip_relative_words():
    """사람이 말한 위치 표현을 떼고, 그래도 안 되면 마지막 단어를 떼서 찾는다 (2026-10-08 실측 예)"""
    assert _place_queries("구룡포시장 바로 뒤") == ["구룡포시장 바로 뒤", "구룡포시장"]
    assert _place_queries("구룡포수협 위판장") == ["구룡포수협 위판장", "구룡포수협"]
    assert _place_queries("구룡포시장") == ["구룡포시장"]


def test_get_user_profile_maps_db_rows():
    from guardian_ai.tools import get_user_profile
    rows = {"u": [{"user_type": "worker", "birth_year": 1956, "mobility": "public_transit", "walking_ability": "limited",
                   "has_dependents": False, "occupation": "fisher, 수산업", "vision_impaired": None, "hearing_impaired": True}],
            "p": [{"place_type": "work", "label": "구룡포항", "lat": 35.99, "lon": 129.56},
                  {"place_type": "home", "label": None, "lat": 35.98, "lon": 129.55}]}
    fetch = lambda sql, params=None: rows["p" if "user_places" in sql else "u"]
    p = get_user_profile("uid", fetch=fetch, today=datetime(2026, 10, 8))["profile"]
    assert p["age"] == 70 and p["mobility"] == "public_transport"
    assert not {"walking_impaired", "has_dependents"} & p.keys()          # 서버에 남은 예전 보행 값은 읽지 않음
    assert p["occupation"] == "어업 종사자·뱃사람, 수산업" and p["hearing_impaired"] is True and "visual_impaired" not in p
    assert p["user_type"] == "resident" and p["home"]["label"] == "집" and p["frequent_places"][0]["label"] == "구룡포항"
    assert get_user_profile("x", fetch=lambda *a, **k: [])["available"] is False
    # DB 기본값(normal·false)은 '입력 안 함'일 수 있어 기준으로 쓰지 않는다 → 앱이 보낸 값이 남는다
    rows["u"][0].update(hearing_impaired=False)
    p = get_user_profile("uid", fetch=fetch)["profile"]
    assert "hearing_impaired" not in p


def test_signed_in_owner_only(monkeypatch):
    """서버 프로필 읽기·고치기는 로그인(익명 제외)한 본인만: 토큰 없음·다른 uid → 둘 다 안 함"""
    monkeypatch.setenv("API_AUTH_MODE", "dev")
    req = ChatRequest(user_id="u9", question="대피소 어디야")
    assert _signed_in(req, None) == {} and _signed_in(req, "Bearer dev:someone-else") == {}
    assert _signed_in(req, "Bearer dev:u9") == {"verified_uid": "u9", "token": "dev:u9"}


def test_chat_endpoint_passes_uid_and_token(monkeypatch):
    monkeypatch.setenv("API_AUTH_MODE", "dev")
    svc = ChatService(classifier=G.keyword_classify)
    seen = []
    real = svc.chat
    monkeypatch.setattr(svc, "chat", lambda req, **kw: (seen.append(kw), real(req, **kw))[1])
    app.dependency_overrides[get_service] = lambda: svc
    try:
        c = TestClient(app)
        c.post("/api/chat", json={"user_id": "u9", "question": "대피소 어디야"})
        c.post("/api/chat", json={"user_id": "u9", "question": "대피소 어디야"}, headers={"Authorization": "Bearer dev:u9"})
        assert c.get("/api/ai/me/memory", headers={"Authorization": "Bearer dev:u9"}).status_code == 404   # 기억 API 없앰
    finally:
        app.dependency_overrides.clear()
    assert seen == [{}, {"verified_uid": "u9", "token": "dev:u9"}]


def test_record_failure_keeps_profile_update():
    def handle(request):
        if request.url.path.endswith("profile-updates"):
            return httpx.Response(503)
        return httpx.Response(200, json={"places": []})
    w = P.ProfileWriter(client=httpx.Client(base_url="http://api", transport=httpx.MockTransport(handle)))
    done = w.apply("tok", [fact("hearing_impaired", "true")])
    assert done["profile"] == {"hearing_impaired": True} and done["recorded"] == 0


@pytest.mark.parametrize("field, value, shown", [
    ("age", "72", "72세"), ("mobility", "wheelchair", "휠체어"),
    ("hearing_impaired", "true", "지원 필요"), ("occupation", "어선 선장", "어선 선장")])
def test_readable(field, value, shown):
    assert P.readable(field, value) == shown


def test_real_service_user_source_calls_tools(monkeypatch):
    """실제 서비스가 쓰는 user_source 가 tools.get_user_profile 을 부른다 (2026-10-08 NameError 로 로그인 채팅 500 재발 방지)"""
    from guardian_ai import service as SV
    from guardian_ai import tools as T
    monkeypatch.setattr(T, "get_user_profile", lambda uid: {"available": True, "profile": {"age": 70}, "uid": uid})
    assert SV.server_profile("u1") == {"available": True, "profile": {"age": 70}, "uid": "u1"}
    svc = ChatService(classifier=G.keyword_classify)
    svc.user_source = SV.server_profile
    assert svc.chat(ChatRequest(user_id="u1", question="대피소 어디야"), verified_uid="u1", token="t").answer
