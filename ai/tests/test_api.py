"""AI 서버 /api/chat 왕복 (Gemini 대신 키워드 분류기)."""

from fastapi.testclient import TestClient

from guardian_ai import graph as G
from guardian_ai.api import app, get_service
from guardian_ai.service import ChatService


def client() -> TestClient:
    service = ChatService(classifier=G.keyword_classify)
    app.dependency_overrides[get_service] = lambda: service
    return TestClient(app)


def test_health():
    assert client().get("/api/ai/health").json() == {"status": "ok"}


def test_chat_roundtrip_and_conversation_continues():
    c = client()
    first = c.post("/api/chat", json={"user_id": "u1", "question": "비 오는데 걸어서 집에 가도 되나요?"})
    assert first.status_code == 200
    body = first.json()
    assert body["answer"]
    assert set(body["selected_agents"]) == {"rain_flood_agent", "location_route_agent"}
    assert body["used_fallback"] is False

    second = c.post("/api/chat", json={
        "user_id": "u1", "question": "태풍은요?", "conversation_id": body["conversation_id"]})
    assert second.json()["conversation_id"] == body["conversation_id"]
    assert second.json()["selected_agents"] == ["wind_typhoon_agent"]


def test_chat_rejects_missing_question():
    assert client().post("/api/chat", json={"user_id": "u1"}).status_code == 422
