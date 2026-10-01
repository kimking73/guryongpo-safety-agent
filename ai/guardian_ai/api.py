"""AI 서버 HTTP 창구 (ai 컨테이너).

배포 시 Caddy가 /api/chat을 이 서버로 넘긴다 (B10). 나머지 /api는 A의 FastAPI 서버.
Firebase 토큰 검증은 A2에서 A가 정하는 방식에 맞춰 추가한다.
"""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from functools import lru_cache

from fastapi import Depends, FastAPI

from . import memory as M
from .service import ChatRequest, ChatResponse, ChatService
from .usage import get_tracker

# guardian_ai 로그(라우팅 결과 등)를 컨테이너 로그에 INFO부터 남긴다
logging.basicConfig(level=logging.WARNING, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logging.getLogger("guardian_ai").setLevel(logging.INFO)

@asynccontextmanager
async def lifespan(app: FastAPI):
    yield
    # 종료 직전: 서비스가 만들어졌다면 백그라운드 기억 저장이 끝날 때까지 기다린다 (재시작 때 기억 유실 방지)
    if get_service.cache_info().currsize:
        get_service().close()


app = FastAPI(title="구룡가디언 AI", lifespan=lifespan)


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
