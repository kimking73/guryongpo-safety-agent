"""음성 (B5): 녹음 → 받아쓰기(STT) → 대화 → 음성 합성(TTS). Google Cloud Speech-to-Text v1 · Text-to-Speech v1 REST.

- 앱은 녹음 파일만 보낸다. Google 키는 서버(ai 컨테이너)만 갖는다 (서버 명세 v0.3 공통 규약).
- 녹음 형식은 기기마다 다르다(웹 webm/opus, 안드로이드·iOS m4a/aac) → ffmpeg로 16kHz mono 16bit PCM으로 바꿔 STT에 보낸다.
- 키: 서비스 계정 JSON 경로 `GCP_VOICE_CREDENTIALS` (예: secrets/gcp-voice.json) 또는 API 키 `GCP_VOICE_API_KEY`
  (조직 정책이 서비스 계정 키 발급을 막을 때 — 두 API는 API 키도 받는다). 둘 다 없으면 available=False → API가 503.
- B12(음성 대피 확인)가 stt·tts를 그대로 쓴다.
"""

from __future__ import annotations

import base64
import logging
import os
import subprocess
import threading
import time
from typing import Any, Callable

import httpx

logger = logging.getLogger(__name__)

STT_URL = "https://speech.googleapis.com/v1/speech:recognize"
TTS_URL = "https://texttospeech.googleapis.com/v1/text:synthesize"
SAMPLE_RATE = 16000
MAX_SECONDS = 30                 # 서버 명세 /voice: 30초 이내
MAX_BYTES = 5 * 1024 * 1024
# 한국어 목소리. Neural2가 자연스럽다. 바꾸려면 GCP_VOICE_NAME (예: ko-KR-Wavenet-A)
DEFAULT_VOICE = "ko-KR-Neural2-A"
SPEAKING_RATE = 0.95             # 노인·관광객이 듣기 쉽게 조금 느리게
TTS_CACHE_S = 600                # 같은 문장(경고 읽기 등)은 10분 동안 다시 합성하지 않는다
TIMEOUT_S = 10.0
DEFAULT_CREDENTIALS = "secrets/gcp-voice.json"
# 연속 음성 대화를 끝내는 말. 받아쓴 문장 전체가 이 중 하나일 때만 끝낸다 ("그만 대피해도 돼?"는 질문이다)
END_PHRASES = {"그만", "그만해", "그만할게", "그만할래", "대화종료", "대화끝", "음성대화종료", "종료", "종료해", "끝", "끝낼게",
               "끝내", "끝내자", "됐어", "됐어요", "이제됐어", "고마워그만", "그만해줘", "종료해줘", "끝내줘"}
END_REPLY = "네, 음성 대화를 마칠게요."


class VoiceUnavailable(Exception):
    """음성 키가 없거나 Google에 닿지 않음 → 503"""


class NoSpeech(Exception):
    """녹음에서 말을 알아듣지 못함 → 422 '다시 말씀해 주세요'"""


class BadAudio(Exception):
    """너무 길거나 변환할 수 없는 녹음 → 422"""


def is_end_phrase(transcript: str) -> bool:
    """받아쓴 말이 '대화를 끝내자'는 뜻인가 — 띄어쓰기·문장부호를 뺀 문장 전체가 END_PHRASES와 같을 때만."""
    return "".join(ch for ch in transcript if ch.isalnum()) in END_PHRASES


def to_pcm16k(data: bytes, run: Callable[..., Any] = subprocess.run) -> bytes:
    """아무 녹음 형식 → 16kHz mono s16le (raw). ffmpeg가 형식을 알아서 읽는다."""
    try:
        out = run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", "pipe:0", "-ac", "1", "-ar", str(SAMPLE_RATE),
                   "-f", "s16le", "pipe:1"], input=data, capture_output=True, timeout=20, check=True)
    except FileNotFoundError as e:
        raise VoiceUnavailable("ffmpeg가 없습니다 (ai 컨테이너에는 포함)") from e
    except subprocess.CalledProcessError as e:
        raise BadAudio("녹음 파일을 읽지 못했습니다") from e
    pcm = out.stdout
    if len(pcm) > MAX_SECONDS * SAMPLE_RATE * 2:
        raise BadAudio(f"녹음이 너무 깁니다. {MAX_SECONDS}초 이내로 말씀해 주세요.")
    if len(pcm) < SAMPLE_RATE * 2 // 4:          # 0.25초 미만
        raise NoSpeech("녹음이 너무 짧습니다")
    return pcm


class GoogleVoice:
    """Google STT·TTS. token()은 서비스 계정 토큰(google-auth)이 만료 전에 알아서 새로 받는다.
    API 키(api_key 또는 GCP_VOICE_API_KEY)가 있으면 토큰 대신 그 키를 머리말(X-Goog-Api-Key)로 보낸다 — 서비스 계정 파일보다 우선.
    http: 테스트에서 가짜 Google을 넣을 때만 (httpx.Client, base 주소 무시하고 전체 URL로 부른다)."""

    def __init__(self, credentials_path: str | None = None, http: httpx.Client | None = None,
                 token: Callable[[], str] | None = None, voice_name: str | None = None, api_key: str | None = None):
        self.voice_name = voice_name or os.environ.get("GCP_VOICE_NAME") or DEFAULT_VOICE
        self.http = http or httpx.Client(timeout=TIMEOUT_S)
        self._token = token
        self._creds = None
        self._lock = threading.Lock()
        self._cache: dict[str, tuple[float, bytes]] = {}
        # 인자 > GCP_VOICE_CREDENTIALS > secrets/gcp-voice.json (키 파일만 넣으면 .env를 안 고쳐도 되게)
        path = credentials_path if credentials_path is not None else (
            os.environ.get("GCP_VOICE_CREDENTIALS") or DEFAULT_CREDENTIALS)
        # 테스트가 토큰·경로를 직접 줄 때는 환경 변수의 API 키를 보지 않는다
        self._api_key = api_key if api_key is not None else (
            (os.environ.get("GCP_VOICE_API_KEY") or "").strip() if token is None and credentials_path is None else "")
        self.available = token is not None or bool(self._api_key) or bool(path and os.path.exists(path))
        self._path = path

    def token(self) -> str:
        if self._token is not None:
            return self._token()
        if not self.available:
            raise VoiceUnavailable("음성 키(GCP_VOICE_CREDENTIALS)가 없습니다")
        from google.auth.transport.requests import Request
        from google.oauth2 import service_account
        with self._lock:
            if self._creds is None:
                self._creds = service_account.Credentials.from_service_account_file(
                    self._path, scopes=["https://www.googleapis.com/auth/cloud-platform"])
            if not self._creds.valid:
                self._creds.refresh(Request())
            return self._creds.token

    def _post(self, url: str, body: dict[str, Any]) -> dict[str, Any]:
        try:
            auth = {"X-Goog-Api-Key": self._api_key} if self._api_key else {"Authorization": f"Bearer {self.token()}"}
            res = self.http.post(url, json=body, headers=auth)
        except httpx.HTTPError as e:
            raise VoiceUnavailable(f"Google 음성 서비스에 연결하지 못했습니다 ({type(e).__name__})") from e
        if res.status_code != 200:
            # 오류 본문에 키가 섞일 일은 없지만, 길게 남기지 않는다
            logger.warning("Google 음성 오류 %s %s", res.status_code, res.text[:200])
            raise VoiceUnavailable(f"Google 음성 서비스 오류 (HTTP {res.status_code})")
        return res.json()

    def stt(self, pcm: bytes) -> str:
        """16kHz mono s16le → 한국어 문장. 알아듣지 못하면 NoSpeech."""
        data = self._post(STT_URL, {
            "config": {"encoding": "LINEAR16", "sampleRateHertz": SAMPLE_RATE, "languageCode": "ko-KR",
                       "enableAutomaticPunctuation": True, "model": "latest_short"},
            "audio": {"content": base64.b64encode(pcm).decode()}})
        text = " ".join(r["alternatives"][0]["transcript"].strip() for r in data.get("results", [])
                        if r.get("alternatives")).strip()
        if not text:
            raise NoSpeech("말씀을 알아듣지 못했습니다")
        return text

    def tts(self, text: str) -> bytes:
        """한국어 문장 → mp3. 같은 문장은 10분 동안 캐시."""
        text = text.strip()
        now = time.monotonic()
        hit = self._cache.get(text)
        if hit and now - hit[0] < TTS_CACHE_S:
            return hit[1]
        data = self._post(TTS_URL, {
            "input": {"text": text[:4500]},          # Google TTS 한 번에 5000바이트 제한 근처에서 자른다
            "voice": {"languageCode": "ko-KR", "name": self.voice_name},
            "audioConfig": {"audioEncoding": "MP3", "speakingRate": SPEAKING_RATE}})
        mp3 = base64.b64decode(data["audioContent"])
        with self._lock:
            self._cache = {k: v for k, v in self._cache.items() if now - v[0] < TTS_CACHE_S}
            self._cache[text] = (now, mp3)
        return mp3
