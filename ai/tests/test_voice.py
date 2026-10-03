"""B5 음성: ffmpeg 변환, Google STT·TTS 호출 형식, /api/voice·/api/tts (가짜 Google·가짜 ffmpeg, 키·네트워크 없이)."""

import base64
import json
import subprocess

import httpx
import pytest
from fastapi.testclient import TestClient

from guardian_ai import api as API
from guardian_ai import graph as G
from guardian_ai import voice as V
from guardian_ai.service import ChatService

PCM_1S = b"\x00\x01" * V.SAMPLE_RATE           # 1초 분량


def fake_google(transcript="비가 많이 오는데 어떻게 해야 해?", status=200, seen=None):
    def handler(req):
        body = json.loads(req.content)
        if seen is not None:
            seen.append((str(req.url), body, req.headers.get("authorization")))
        if status != 200:
            return httpx.Response(status, json={"error": {"message": "nope"}})
        if "speech:recognize" in str(req.url):
            results = [{"alternatives": [{"transcript": transcript}]}] if transcript else []
            return httpx.Response(200, json={"results": results})
        return httpx.Response(200, json={"audioContent": base64.b64encode(b"MP3:" + body["input"]["text"].encode()).decode()})
    return V.GoogleVoice(token=lambda: "tok", http=httpx.Client(transport=httpx.MockTransport(handler)))


# --- 변환 -----------------------------------------------------------------------

def test_to_pcm_calls_ffmpeg_for_16k_mono_and_checks_length():
    calls = []

    def run(cmd, **kw):
        calls.append(cmd)
        return subprocess.CompletedProcess(cmd, 0, stdout=PCM_1S)
    assert V.to_pcm16k(b"webm", run=run) == PCM_1S
    assert calls[0][:2] == ["ffmpeg", "-hide_banner"] and "16000" in calls[0] and "s16le" in calls[0]
    too_long = lambda cmd, **kw: subprocess.CompletedProcess(cmd, 0, stdout=PCM_1S * (V.MAX_SECONDS + 1))  # noqa: E731
    with pytest.raises(V.BadAudio):
        V.to_pcm16k(b"x", run=too_long)
    with pytest.raises(V.NoSpeech):
        V.to_pcm16k(b"x", run=lambda cmd, **kw: subprocess.CompletedProcess(cmd, 0, stdout=b"\x00" * 100))

    def broken(cmd, **kw):
        raise subprocess.CalledProcessError(1, cmd)
    with pytest.raises(V.BadAudio):
        V.to_pcm16k(b"x", run=broken)


# --- Google 호출 형식 -------------------------------------------------------------

def test_stt_and_tts_request_shape_and_tts_cache():
    seen = []
    g = fake_google(seen=seen)
    assert g.stt(PCM_1S) == "비가 많이 오는데 어떻게 해야 해?"
    url, body, auth = seen[0]
    assert "speech:recognize" in url and auth == "Bearer tok"
    assert body["config"]["languageCode"] == "ko-KR" and body["config"]["sampleRateHertz"] == 16000
    assert g.tts("대피하세요.") == "MP3:대피하세요.".encode() and g.tts("대피하세요.") == "MP3:대피하세요.".encode()
    tts_calls = [s for s in seen if "text:synthesize" in s[0]]
    assert len(tts_calls) == 1 and tts_calls[0][1]["voice"]["name"] == V.DEFAULT_VOICE   # 두 번째는 캐시


def test_stt_without_speech_and_google_errors():
    with pytest.raises(V.NoSpeech):
        fake_google(transcript="").stt(PCM_1S)
    with pytest.raises(V.VoiceUnavailable):
        fake_google(status=403).stt(PCM_1S)


def test_no_credentials_means_unavailable(monkeypatch):
    monkeypatch.delenv("GCP_VOICE_CREDENTIALS", raising=False)
    assert not V.GoogleVoice().available


# --- API ------------------------------------------------------------------------

@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(API, "to_pcm16k", lambda data: PCM_1S)                  # ffmpeg 없이
    service = ChatService(classifier=G.keyword_classify)
    API.app.dependency_overrides[API.get_service] = lambda: service

    def use(google):
        API.app.dependency_overrides[API.get_voice] = lambda: google
        return TestClient(API.app)
    yield use
    API.app.dependency_overrides.clear()


def test_voice_round_trip(client):
    c = client(fake_google())
    res = c.post("/api/voice", data={"user_id": "u1", "lat": "35.99", "lon": "129.55"},
                 files={"audio": ("q.webm", b"webm-bytes", "audio/webm")})
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["transcript"] == "비가 많이 오는데 어떻게 해야 해?" and body["answer"]
    assert base64.b64decode(body["audio_b64"]).startswith(b"MP3:")
    assert {"stt", "tts", "voice_total", "total"} <= set(body["timings"])


def test_voice_errors(client):
    assert client(fake_google(transcript="")).post(
        "/api/voice", data={"user_id": "u1"}, files={"audio": ("q.webm", b"x", "audio/webm")}).status_code == 422
    unavailable = V.GoogleVoice(credentials_path="")
    assert client(unavailable).post(
        "/api/voice", data={"user_id": "u1"}, files={"audio": ("q.webm", b"x", "audio/webm")}).status_code == 503
    big = b"x" * (V.MAX_BYTES + 1)
    assert client(fake_google()).post(
        "/api/voice", data={"user_id": "u1"}, files={"audio": ("q.webm", big, "audio/webm")}).status_code == 422


def test_tts_endpoint(client):
    c = client(fake_google())
    res = c.post("/api/tts", json={"text": "침수 경보입니다."})
    assert res.status_code == 200 and res.headers["content-type"] == "audio/mpeg" and res.content == "MP3:침수 경보입니다.".encode()
    assert c.post("/api/tts", json={"text": "  "}).status_code == 422
    assert client(V.GoogleVoice(credentials_path="")).post("/api/tts", json={"text": "x"}).status_code == 503
