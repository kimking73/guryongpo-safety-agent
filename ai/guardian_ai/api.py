"""AI 서버 HTTP 창구 (ai 컨테이너).

배포 시 Caddy가 /api/chat을 이 서버로 넘긴다 (B10). 나머지 /api는 A의 FastAPI 서버.
Firebase 토큰 검증은 A2에서 A가 정하는 방식에 맞춰 추가한다.
"""

from __future__ import annotations

import base64
import logging
import os
from contextlib import asynccontextmanager
from functools import lru_cache

from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import Response
from pydantic import BaseModel
from fastapi.middleware.cors import CORSMiddleware

from . import memory as M
from . import state as S
from .service import ChatRequest, ChatResponse, ChatService
from .voice import MAX_BYTES, BadAudio, GoogleVoice, NoSpeech, VoiceUnavailable, to_pcm16k
from .usage import get_tracker

# guardian_ai 로그(라우팅 결과 등)를 컨테이너 로그에 INFO부터 남긴다
logging.basicConfig(level=logging.WARNING, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logging.getLogger("guardian_ai").setLevel(logging.INFO)
logger = logging.getLogger("guardian_ai.api")

@asynccontextmanager
async def lifespan(app: FastAPI):
    yield
    # 종료 직전: 서비스가 만들어졌다면 백그라운드 기억 저장이 끝날 때까지 기다린다 (재시작 때 기억 유실 방지)
    if get_service.cache_info().currsize:
        get_service().close()


app = FastAPI(title="구룡가디언 AI", lifespan=lifespan)
# 브라우저(Flutter 웹)가 이 포트를 직접 부를 때 필요 (로컬). 배포에서는 Caddy가 같은 도메인으로 묶는다
app.add_middleware(CORSMiddleware, allow_origins=[o.strip() for o in (os.environ.get("CORS_ORIGINS") or "*").split(",") if o.strip()],
                   allow_methods=["*"], allow_headers=["*"])


@lru_cache
def get_service() -> ChatService:
    """서버 전체에서 하나만 만든다 (대화 기억을 공유). 테스트는 dependency_overrides로 바꾼다."""
    return ChatService()


@app.get("/api/ai/health")
def health() -> dict:
    return {"status": "ok"}


@app.get("/api/ai/usage")
def usage() -> dict:
    """이번 달 OpenAI 호출 수·토큰·예상 비용과 월 예산 대비 비율 (usage.py)."""
    return get_tracker().summary()


# 사용자 기억 보기·지우기. 인증(Firebase 토큰)은 A의 방식이 정해지면 붙인다 — 그 전에는 외부에 열지 않는다
# (배포 시 Caddy가 /api/ai/memory를 넘기지 않게, B10).
@app.get("/api/ai/memory/{user_id}")
def get_memory(user_id: str, service: ChatService = Depends(get_service)) -> dict:
    return {**M.export(service.store, user_id), "backend": service.memory_backend}


@app.delete("/api/ai/memory/{user_id}")
def delete_memory(user_id: str, service: ChatService = Depends(get_service)) -> dict:
    return {"user_id": user_id, "deleted": M.forget(service.store, user_id)}


@app.post("/api/chat", response_model=ChatResponse)
def chat(req: ChatRequest, service: ChatService = Depends(get_service)) -> ChatResponse:
    return service.chat(req)


# --- 음성 (B5) -----------------------------------------------------------------

@lru_cache
def get_voice() -> GoogleVoice:
    """서버 전체에서 하나 (토큰·TTS 캐시 공유). 테스트는 dependency_overrides로 가짜 Google을 넣는다."""
    return GoogleVoice()


class VoiceResponse(ChatResponse):
    """POST /api/voice 응답 = 채팅 응답 + 받아쓴 질문 + 답 음성(mp3, base64). 음성 합성에 실패하면 audio_b64는 null."""
    transcript: str
    audio_b64: str | None = None


class TtsRequest(BaseModel):
    text: str


def _voice_error(e: Exception) -> HTTPException:
    if isinstance(e, VoiceUnavailable):
        return HTTPException(503, f"음성 기능을 지금 쓸 수 없습니다. {e}")
    return HTTPException(422, str(e) if isinstance(e, BadAudio) else "말씀을 알아듣지 못했습니다. 다시 말씀해 주세요.")


@app.post("/api/voice", response_model=VoiceResponse)
def voice(audio: UploadFile = File(...), user_id: str = Form(...), conversation_id: str | None = Form(None),
          lat: float | None = Form(None), lon: float | None = Form(None), profile: str | None = Form(None),
          remember: bool = Form(True), service: ChatService = Depends(get_service),
          google: GoogleVoice = Depends(get_voice)) -> VoiceResponse:
    """녹음 업로드 → 받아쓰기 → /api/chat과 같은 대화 → 답의 voice_text를 음성으로. profile은 ChatRequest.profile과 같은 JSON 문자열."""
    import time as _t
    if not google.available:
        raise HTTPException(503, "음성 기능이 아직 준비되지 않았습니다 (GCP_VOICE_CREDENTIALS)")
    data = audio.file.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise HTTPException(422, "녹음 파일이 너무 큽니다. 30초 이내로 말씀해 주세요.")
    t0 = _t.perf_counter()
    try:
        transcript = google.stt(to_pcm16k(data))
    except (VoiceUnavailable, NoSpeech, BadAudio) as e:
        raise _voice_error(e) from e
    t_stt = _t.perf_counter() - t0
    req = ChatRequest(
        user_id=user_id, question=transcript, conversation_id=conversation_id, remember=remember,
        current_location=S.Location(lat=lat, lon=lon) if lat is not None and lon is not None else None,
        profile=S.UserProfile.model_validate_json(profile) if profile else None)
    res = service.chat(req)
    t1 = _t.perf_counter()
    try:
        audio_b64 = base64.b64encode(google.tts(res.voice_text or res.answer)).decode()
    except VoiceUnavailable as e:
        logger.warning("답 음성 합성 실패 — 글 답만 보낸다 (%s)", e)
        audio_b64 = None
    timings = {**res.timings, "stt": round(t_stt, 2), "tts": round(_t.perf_counter() - t1, 2),
               "voice_total": round(_t.perf_counter() - t0, 2)}
    logger.info("음성 응답 %.1fs (받아쓰기 %.1f, 음성 %.1f) '%s'", timings["voice_total"], t_stt, timings["tts"], transcript)
    return VoiceResponse(**{**res.model_dump(), "timings": timings}, transcript=transcript, audio_b64=audio_b64)


@app.post("/api/tts", responses={200: {"content": {"audio/mpeg": {}}}})
def tts(req: TtsRequest, google: GoogleVoice = Depends(get_voice)) -> Response:
    """문장 → mp3 (앱 '음성으로 듣기', 경고 읽기). 같은 문장은 10분 캐시."""
    if not google.available:
        raise HTTPException(503, "음성 기능이 아직 준비되지 않았습니다 (GCP_VOICE_CREDENTIALS)")
    if not req.text.strip():
        raise HTTPException(422, "읽을 문장이 없습니다")
    try:
        return Response(google.tts(req.text), media_type="audio/mpeg")
    except VoiceUnavailable as e:
        raise _voice_error(e) from e

