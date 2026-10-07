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
