"""LangSmith 추적 (선택, 2026-10-10) — 질문 하나가 어느 노드를 거쳐 어떤 지시문·답·시간·토큰으로 처리됐는지 웹에서 본다.

켜는 법 (루트 .env): LANGSMITH_TRACING=true + LANGSMITH_API_KEY. 키가 없으면 아무것도 보내지 않는다 (테스트·기본값).
보내는 범위 `LANGSMITH_TRACE_SCOPE`:
- demo (기본): 시연 모드 대화(ChatRequest.demo)만. 실제 사용자 대화의 위치·나이·장애 정보는 외부로 나가지 않는다.
- all: 모든 대화. 실제 사용자 데이터가 LangSmith 서버에 저장되므로 동의·가림 처리를 정한 뒤에만 쓴다.
LangGraph 노드는 자동으로 기록되고, OpenAI 호출(지시문·답·토큰)은 `wrap_client`가 감싼 클라이언트가 기록한다.
"""
from __future__ import annotations

import os
from contextlib import contextmanager


def configured() -> bool:
    """추적을 켰고 키도 있는가 (환경 변수)."""
    on = (os.environ.get("LANGSMITH_TRACING") or "").strip().lower() in ("true", "1", "yes")
    return on and bool((os.environ.get("LANGSMITH_API_KEY") or "").strip())


def allowed(demo: bool) -> bool:
    """이 대화를 보내도 되는가: 켜져 있고, 범위가 all 이거나 시연 모드 대화일 때만."""
    if not configured():
        return False
    scope = (os.environ.get("LANGSMITH_TRACE_SCOPE") or "demo").strip().lower()
    return scope == "all" or bool(demo)


@contextmanager
def scope(demo: bool):
    """이 블록 안의 그래프 실행·OpenAI 호출을 보낼지 정한다. 꺼야 할 때는 환경 변수가 켜져 있어도 확실히 끈다."""
    from langsmith import tracing_context
    with tracing_context(enabled=allowed(demo)):
        yield


def wrap_client(client):
    """OpenAI 클라이언트를 추적용으로 감싼다 (켜져 있을 때만). 실제로 보낼지는 호출 시점의 `scope`가 정한다."""
    if not configured():
        return client
    from langsmith.wrappers import wrap_openai
    return wrap_openai(client)
