"""실시간 음성 대화: Realtime 세션 설정(도구 강제), 임시 키 발급 형식, /api/voice/session (가짜 OpenAI, 키·네트워크 없이)."""

import json

import httpx
from fastapi.testclient import TestClient

from guardian_ai import api as API
from guardian_ai import realtime as R


def test_session_forces_tools_so_the_model_never_answers_by_itself(monkeypatch):
    monkeypatch.delenv("OPENAI_REALTIME_MODEL", raising=False)
    monkeypatch.delenv("OPENAI_REALTIME_VOICE", raising=False)
    c = R.session_config()
    assert c["type"] == "realtime" and c["model"] == "gpt-realtime-2" and c["tool_choice"] == "required"
    assert [t["name"] for t in c["tools"]] == [R.ASK_TOOL, R.END_TOOL]
    assert c["tools"][0]["parameters"]["required"] == ["question"]
    vad = c["audio"]["input"]["turn_detection"]
    assert vad["create_response"] and vad["interrupt_response"]          # 말 끝 자동 응답 · 끼어들면 멈춤
    assert c["audio"]["input"]["transcription"]["language"] == "ko"
    monkeypatch.setenv("OPENAI_REALTIME_MODEL", "gpt-realtime-2.1-mini")
    monkeypatch.setenv("OPENAI_REALTIME_VOICE", "cedar")
    c = R.session_config()
    assert c["model"] == "gpt-realtime-2.1-mini" and c["audio"]["output"]["voice"] == "cedar"


def test_read_out_instruction_keeps_the_answer_as_is():
    text = "침수심이 230mm입니다. 구룡포중학교 앞까지 1187m입니다."
    assert R.read_out_instructions(text).endswith(text) and "그대로" in R.read_out_instructions(text)


def fake_openai(seen, status=200):
    def handler(req):
        seen.append((str(req.url), req.headers.get("authorization"), json.loads(req.content)))
        if status != 200:
            return httpx.Response(status, json={"error": {"message": "nope"}})
        return httpx.Response(200, json={"value": "ek_test", "expires_at": 123, "session": {}})
    return httpx.Client(transport=httpx.MockTransport(handler))


def test_client_secret_request_and_result():
    seen = []
    out = R.create_client_secret(http=fake_openai(seen), api_key="sk-real")
    url, auth, body = seen[0]
    assert url == R.CLIENT_SECRETS_URL and auth == "Bearer sk-real"
    assert body["session"] == R.session_config() and body["expires_after"]["seconds"] == R.SECRET_TTL_S
    assert out["client_secret"] == "ek_test" and out["calls_url"] == R.CALLS_URL
    assert (out["ask_tool"], out["end_tool"]) == (R.ASK_TOOL, R.END_TOOL)
    assert "sk-real" not in json.dumps(out)                                # 진짜 키는 응답에 없다


def test_unavailable_without_key_or_on_openai_error():
    for kwargs in ({"api_key": ""}, {"api_key": "sk", "http": fake_openai([], status=401)}):
        try:
            R.create_client_secret(**kwargs)
            raise AssertionError("RealtimeUnavailable이어야 한다")
        except R.RealtimeUnavailable:
            pass


def test_voice_session_endpoint(monkeypatch):
    monkeypatch.setattr(R, "create_client_secret", lambda: {
        "client_secret": "ek_x", "expires_at": 1, "model": "gpt-realtime-2", "calls_url": R.CALLS_URL,
        "ask_tool": R.ASK_TOOL, "end_tool": R.END_TOOL, "read_out_prefix": R.read_out_instructions("")})
    res = TestClient(API.app).post("/api/voice/session")
    assert res.status_code == 200 and res.json()["client_secret"] == "ek_x"

    def down():
        raise R.RealtimeUnavailable("OPENAI_API_KEY가 없습니다")
    monkeypatch.setattr(R, "create_client_secret", down)
    assert TestClient(API.app).post("/api/voice/session").status_code == 503


# ---- 시각장애인 대피 음성 확인 (B12) ----

def test_evac_check_session_asks_three_choices_and_has_status_tool(monkeypatch):
    monkeypatch.delenv("OPENAI_REALTIME_MODEL", raising=False)
    c = R.evac_session_config("evac_check", alert_text="구룡포읍 침수 대피 경보")
    assert c["model"] == "gpt-realtime-2" and c["tool_choice"] == "auto"
    assert [t["name"] for t in c["tools"]] == [R.STATUS_TOOL, R.END_TOOL]
    status = c["tools"][0]["parameters"]["properties"]["status"]
    assert status["enum"] == ["evacuated", "evacuating", "need_help"]
    for word in ("대피 완료", "대피 중", "도움 필요", "구룡포읍 침수 대피 경보."):
        assert word in c["instructions"]
    assert c["audio"]["input"]["turn_detection"]["create_response"]           # 대답을 듣는다


def test_announce_session_only_reads_text():
    c = R.evac_session_config("announce", announce_text="방재단원이 배정되었습니다. 약 7분 후 도착합니다.")
    assert [t["name"] for t in c["tools"]] == [R.END_TOOL]
    assert "약 7분 후 도착합니다." in c["instructions"]
    assert c["audio"]["input"]["turn_detection"]["create_response"] is False  # 듣고 답하지 않는다
    for bad in ({"mode": "announce"}, {"mode": "chat"}):
        try:
            R.evac_session_config(**bad)
            raise AssertionError("ValueError여야 한다")
        except ValueError:
            pass


def test_evac_client_secret_result():
    seen = []
    out = R.create_evac_client_secret("evac_check", alert_text="경보", http=fake_openai(seen), api_key="sk-real")
    assert seen[0][2]["session"]["tools"][0]["name"] == R.STATUS_TOOL
    assert out["client_secret"] == "ek_test" and out["status_tool"] == R.STATUS_TOOL and out["mode"] == "evac_check"
    assert out["statuses"] == list(R.EVAC_STATUSES) and "sk-real" not in json.dumps(out)


def test_evac_session_endpoint(monkeypatch):
    def fake(mode, alert_text="", announce_text=""):
        if mode == "announce" and not announce_text:
            raise ValueError("읽을 문장이 없습니다")
        return {"client_secret": "ek_e", "expires_at": 1, "model": "gpt-realtime-2", "calls_url": R.CALLS_URL,
                "mode": mode, "status_tool": R.STATUS_TOOL, "end_tool": R.END_TOOL,
                "statuses": list(R.EVAC_STATUSES), "read_out_prefix": ""}
    monkeypatch.setattr(R, "create_evac_client_secret", fake)
    client = TestClient(API.app)
    res = client.post("/api/voice/evac-session", json={"mode": "evac_check", "alert_text": "경보"})
    assert res.status_code == 200 and res.json()["status_tool"] == R.STATUS_TOOL
    assert client.post("/api/voice/evac-session", json={"mode": "announce"}).status_code == 422
    assert client.post("/api/voice/evac-session", json={"mode": "chat"}).status_code == 422

    def down(*a, **k):
        raise R.RealtimeUnavailable("OPENAI_API_KEY가 없습니다")
    monkeypatch.setattr(R, "create_evac_client_secret", down)
    assert client.post("/api/voice/evac-session", json={"mode": "evac_check"}).status_code == 503
