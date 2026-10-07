"""내 기억 API (/api/ai/me/memory): 로그인한 본인 기억만 보고 지운다 (2026-10-07, 앱 프로필 반영용)."""

import pytest
from fastapi.testclient import TestClient

from guardian_ai import graph as G
from guardian_ai import memory as M
from guardian_ai.api import app, get_service
from guardian_ai.llm import MemoryFact, MemoryUpdate
from guardian_ai.service import ChatService


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("API_AUTH_MODE", "dev")
    svc = ChatService(classifier=G.keyword_classify)
    M.save(svc.store, "u1", "c1", MemoryUpdate(facts=[MemoryFact(field="age", value="78", quote="저는 78살이에요"),
                                                      MemoryFact(field="note", value="보청기 사용", quote="보청기를 껴요")],
                                               summary="대피소를 물어봄"))
    M.save(svc.store, "u2", "c2", MemoryUpdate(facts=[MemoryFact(field="age", value="30", quote="30살")], summary="x"))
    app.dependency_overrides[get_service] = lambda: svc
    yield TestClient(app), svc
    app.dependency_overrides.clear()


def test_reads_only_own_memory(client):
    c, _ = client
    res = c.get("/api/ai/me/memory", headers={"Authorization": "Bearer dev:u1"}).json()
    assert res["user_id"] == "u1" and res["facts"]["age"]["value"] == "78"
    assert res["facts"]["age"]["quote"] == "저는 78살이에요" and res["episodes"][0]["summary"] == "대피소를 물어봄"


def test_needs_login(client, monkeypatch):
    c, _ = client
    assert c.get("/api/ai/me/memory").status_code == 401
    monkeypatch.setenv("API_AUTH_MODE", "firebase")
    assert c.get("/api/ai/me/memory", headers={"Authorization": "Bearer dev:u1"}).status_code == 401


def test_forget_one_fact(client):
    c, svc = client
    key = "note:보청기 사용"
    res = c.delete(f"/api/ai/me/memory/facts/{key}", headers={"Authorization": "Bearer dev:u1"}).json()
    assert res == {"key": key, "deleted": True}
    facts, _ = M.load(svc.store, "u1")
    assert set(facts) == {"age"} and M.load(svc.store, "u2")[0]["age"]["value"] == "30"


def test_chat_remembers_only_for_signed_in_owner(client):
    """장기 기억은 로그인(익명 제외)한 본인만 (2026-10-08): 토큰 없음·다른 uid → remember=False"""
    from guardian_ai.api import _remember_only_signed_in
    from guardian_ai.service import ChatRequest
    req = ChatRequest(user_id="u9", question="대피소 어디야")
    assert _remember_only_signed_in(req, None).remember is False
    assert _remember_only_signed_in(req, "Bearer dev:someone-else").remember is False
    assert _remember_only_signed_in(req, "Bearer dev:u9").remember is True
    assert _remember_only_signed_in(req.model_copy(update={"remember": False}), "Bearer dev:u9").remember is False


def test_chat_endpoint_applies_the_rule(client, monkeypatch):
    c, svc = client
    seen = []
    real = svc.chat
    monkeypatch.setattr(svc, "chat", lambda req, **kw: (seen.append(req.remember), real(req, **kw))[1])
    c.post("/api/chat", json={"user_id": "u9", "question": "대피소 어디야"})
    c.post("/api/chat", json={"user_id": "u9", "question": "대피소 어디야"}, headers={"Authorization": "Bearer dev:u9"})
    assert seen == [False, True]


def test_place_facts_keep_coordinates():
    """집 주소·자주 가는 곳은 저장할 때 좌표를 찾아 함께 남긴다 (2026-10-08). 집 주소는 하나만(덮어씀), 못 찾으면 글자만"""
    from langgraph.store.memory import InMemoryStore
    store = InMemoryStore()
    found = {"구룡포시장": {"lat": 35.987, "lon": 129.553, "address": "경북 포항시 남구 구룡포읍 구룡포길 1"}}
    upd = MemoryUpdate(facts=[MemoryFact(field="home_address", value="구룡포시장", quote="집이 구룡포시장 바로 뒤예요"),
                              MemoryFact(field="frequent_place", value="어딘가 모를 곳", quote="자주 가요")], summary="x")
    M.save(store, "u1", "c1", upd, locate=lambda t: found.get(t))
    facts, _ = M.load(store, "u1")
    assert facts["home_address"]["lat"] == 35.987 and facts["home_address"]["address"].endswith("구룡포길 1")
    assert "lat" not in facts["frequent_place:어딘가 모를 곳"]
    M.save(store, "u1", "c2", MemoryUpdate(facts=[MemoryFact(field="home_address", value="호미로 152", quote="이사했어요")], summary="y"),
           locate=lambda t: None)
    facts, _ = M.load(store, "u1")
    assert facts["home_address"]["value"] == "호미로 152" and "lat" not in facts["home_address"]


def test_place_queries_strip_relative_words():
    """사람이 말한 위치 표현을 떼고, 그래도 안 되면 마지막 단어를 떼서 찾는다 (2026-10-08 실측 예)"""
    from guardian_ai.service import _place_queries
    assert _place_queries("구룡포시장 바로 뒤") == ["구룡포시장 바로 뒤", "구룡포시장"]
    assert _place_queries("구룡포수협 위판장") == ["구룡포수협 위판장", "구룡포수협"]
    assert _place_queries("구룡포초등학교 앞") == ["구룡포초등학교 앞", "구룡포초등학교"]
    assert _place_queries("구룡포시장") == ["구룡포시장"]


def test_server_profile_is_the_source(monkeypatch):
    """로그인 확인된 사용자는 서버 프로필(user_profiles·user_places)이 기준 (2026-10-08). 앱 값은 빈 칸만 보충,
    기억의 프로필 항목은 프로필에 넣지 않고 문장에서도 빠진다 (메모·대화 요약만 남음)"""
    from guardian_ai import memory as M
    from guardian_ai import state as S
    from guardian_ai.graph import keyword_classify
    from guardian_ai.service import ChatRequest, ChatService
    svc = ChatService(classifier=keyword_classify)
    svc.user_source = lambda uid: {"available": True, "profile": {"age": 70, "occupation": "어업",
                                                                   "home": {"lat": 35.98, "lon": 129.56, "label": "집"}}}
    from guardian_ai.llm import MemoryFact, MemoryUpdate
    M.save(svc.store, "u1", "c0", MemoryUpdate(facts=[
        MemoryFact(field="age", value="50", quote="저 50살"),
        MemoryFact(field="note", value="고양이를 키움", quote="고양이 있어요")], summary="대피소를 물음"))
    seen = {}
    real = svc.app.stream
    def spy(state, *a, **kw):
        seen["user"], seen["memory"] = state["user"], state.get("user_memory", [])
        return real(state, *a, **kw)
    monkeypatch.setattr(svc.app, "stream", spy)
    svc.chat(ChatRequest(user_id="u1", question="대피소 어디야",
                         profile=S.UserProfile(user_id="u1", age=40, has_dependents=True)), verified_uid="u1")
    u = seen["user"]
    assert u.age == 70 and u.occupation == "어업" and u.home.label == "집" and u.has_dependents is True
    assert not any("50" in line for line in seen["memory"]) and any("고양이" in line for line in seen["memory"])


def test_get_user_profile_maps_db_rows():
    from datetime import datetime
    from guardian_ai.tools import get_user_profile
    rows = {"u": [{"user_type": "worker", "birth_year": 1956, "mobility": "public_transit", "walking_ability": "limited",
                   "has_dependents": False, "occupation": " 어업 ", "vision_impaired": None, "hearing_impaired": True}],
            "p": [{"place_type": "work", "label": "구룡포항", "lat": 35.99, "lon": 129.56},
                  {"place_type": "home", "label": None, "lat": 35.98, "lon": 129.55}]}
    fetch = lambda sql, params=None: rows["p" if "user_places" in sql else "u"]
    p = get_user_profile("uid", fetch=fetch, today=datetime(2026, 10, 8))["profile"]
    assert p["age"] == 70 and p["mobility"] == "public_transport" and p["walking_impaired"] is True
    assert p["occupation"] == "어업" and p["hearing_impaired"] is True and "visual_impaired" not in p
    assert p["user_type"] == "resident" and p["home"]["label"] == "집" and p["frequent_places"][0]["label"] == "구룡포항"
    assert get_user_profile("x", fetch=lambda *a, **k: [])["available"] is False
    # DB 기본값(normal·false)은 '입력 안 함'일 수 있어 기준으로 쓰지 않는다 → 앱이 보낸 값이 남는다
    rows["u"][0].update(walking_ability="normal", has_dependents=False, hearing_impaired=False)
    p = get_user_profile("uid", fetch=fetch)["profile"]
    assert not {"walking_impaired", "has_dependents", "hearing_impaired"} & p.keys()
