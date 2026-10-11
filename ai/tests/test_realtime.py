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
