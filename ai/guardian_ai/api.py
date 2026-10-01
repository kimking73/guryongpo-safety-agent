"""AI 서버 HTTP 창구 (ai 컨테이너).

배포 시 Caddy가 /api/chat을 이 서버로 넘긴다 (B10). 나머지 /api는 A의 FastAPI 서버.
Firebase 토큰 검증은 A2에서 A가 정하는 방식에 맞춰 추가한다.
"""

from __future__ import annotations

import logging
from functools import lru_cache

from fastapi import Depends, FastAPI

from .service import ChatRequest, ChatResponse, ChatService
from .usage import get_tracker

# guardian_ai 로그(라우팅 결과 등)를 컨테이너 로그에 INFO부터 남긴다
logging.basicConfig(level=logging.WARNING, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logging.getLogger("guardian_ai").setLevel(logging.INFO)

app = FastAPI(title="구룡가디언 AI")


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


@app.post("/api/chat", response_model=ChatResponse)
def chat(req: ChatRequest, service: ChatService = Depends(get_service)) -> ChatResponse:
    return service.chat(req)
