"""대화 · 음성 (목업) — 실구현은 B 의 LangGraph Agent 와 연결"""
import uuid
from typing import Optional

from fastapi import APIRouter, Depends, File, Form, UploadFile

from .. import mocks
from ..auth import AuthUser, current_user
from ..errors import ApiError
from ..schemas import ChatRequest

router = APIRouter(tags=["chat"])
AUDIO_TYPES = ("audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac", "audio/webm", "audio/wav", "audio/x-wav",
               "audio/wave", "video/webm", "application/octet-stream")
MAX_AUDIO_BYTES = 5 * 1024 * 1024     # 30초 녹음 기준 넉넉히


@router.post("/chat", summary="텍스트 질문 → Agent 답변")
def post_chat(body: ChatRequest, u: AuthUser = Depends(current_user)):
    d = mocks.load("chat.json")
    if body.session_id:
        d["session_id"] = str(body.session_id)
    if not body.want_audio:
        d["message"]["audio_url"] = None
    return mocks.respond(d)


@router.get("/chat/sessions", summary="대화 목록")
def list_sessions(u: AuthUser = Depends(current_user)):
    d = mocks.load("chat.json")
    t = d["message"].get("created_at") or mocks.now_iso()
    return mocks.respond([{"id": d["session_id"], "title": "배 보러 부두에 가도 되나요?", "created_at": t, "updated_at": t}])


@router.get("/chat/sessions/{session_id}", summary="대화 내역")
def get_session(session_id: uuid.UUID, u: AuthUser = Depends(current_user)):
    d = mocks.load("chat.json")
    if str(session_id) != d["session_id"]:
        raise ApiError("NOT_FOUND")
    t = d["message"].get("created_at") or mocks.now_iso()
    return mocks.respond({"id": d["session_id"], "title": "배 보러 부두에 가도 되나요?", "created_at": t,
                          "updated_at": t, "messages": [d["message"]]})


@router.post("/voice", summary="녹음 업로드 → STT → Agent → TTS")
async def post_voice(audio: UploadFile = File(...), session_id: Optional[uuid.UUID] = Form(None),
                     lat: Optional[float] = Form(None), lng: Optional[float] = Form(None),
                     u: AuthUser = Depends(current_user)):
    data = await audio.read()
    if not data:
        raise ApiError("STT_FAILED", detail="empty_audio")
    if len(data) > MAX_AUDIO_BYTES:
        raise ApiError("VALIDATION_ERROR", "녹음이 너무 깁니다. 30초 이내로 말씀해 주세요.", detail="audio_too_large")
    if audio.content_type and audio.content_type.split(";")[0] not in AUDIO_TYPES:
        raise ApiError("VALIDATION_ERROR", "지원하지 않는 녹음 형식입니다.", detail=audio.content_type)
    d = mocks.load("voice.json")
    if session_id:
        d["session_id"] = str(session_id)
    return mocks.respond(d)


@router.get("/voice/audio/{audio_id}", summary="TTS mp3 (목업: 없음)")
def get_voice_audio(audio_id: str):
    raise ApiError("NOT_FOUND", "음성 파일이 준비되지 않았습니다.", detail="mock_has_no_audio")
