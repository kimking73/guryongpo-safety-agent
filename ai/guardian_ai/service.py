"""채팅 서비스: 앱 요청 → 그래프 실행 → 응답.

HTTP 창구는 api.py, 이 파일은 요청·응답 형식과 대화 기억(checkpointer)을 맡는다.
"""

from __future__ import annotations

import uuid

from langgraph.checkpoint.memory import InMemorySaver
from langgraph.checkpoint.serde.jsonplus import JsonPlusSerializer
from pydantic import BaseModel, Field

from . import graph as G
from . import state as S

# 대화 기억에 저장·복원해도 되는 우리 타입 (code_check_list.md 4번).
# 새 모델·enum을 state.py에 추가하면 여기에도 추가한다.
STATE_TYPES = [
    S.DisasterType, S.Phase, S.RiskLevel, S.Specialist, S.Mobility,
    S.Location, S.UserProfile, S.Evidence, S.RiskEvent, S.SpecialistResult,
    S.ActionPlan, S.CheckResult, S.ActionGuide,
]


class ChatRequest(BaseModel):
    """앱 → AI. 초안 형식이며 C와 맞추며 바뀔 수 있다."""
    user_id: str
    question: str
    profile: S.UserProfile | None = None          # 없으면 user_id만 있는 기본 프로필
    current_location: S.Location | None = None
    conversation_id: str | None = None             # 없으면 새 대화를 시작한다


class ChatResponse(BaseModel):
    """AI → 앱. 카드형 답변(수치 칩·할 일·출처)은 B5 다듬기에서 확장한다."""
    conversation_id: str
    answer: str
    selected_agents: list[S.Specialist] = Field(default_factory=list)
    phase: S.Phase = S.Phase.NONE
    used_fallback: bool = False


def make_checkpointer() -> InMemorySaver:
    """대화 기억. 지금은 메모리(재시작하면 사라짐), 이후 PostgreSQL 저장으로 바꿀 수 있다."""
    return InMemorySaver(serde=JsonPlusSerializer(allowed_msgpack_modules=STATE_TYPES))


class ChatService:
    def __init__(self, classifier: G.Classifier | None = None, checkpointer=None):
        """classifier를 안 주면 Gemini 분류기를 쓴다 (GEMINI_API_KEY 필요)."""
        if classifier is None:
            from .llm import GeminiClassifier   # 키가 없는 테스트 환경에서 import 오류를 피한다
            classifier = GeminiClassifier()
        self.app = G.build_graph(
            {G.MANAGER: G.make_manager(classifier)},
            checkpointer=checkpointer or make_checkpointer(),
        )

    def chat(self, req: ChatRequest) -> ChatResponse:
        conversation_id = req.conversation_id or uuid.uuid4().hex
        config = {"configurable": {"thread_id": conversation_id}}
        history = self.app.get_state(config).values.get("history", [])

        result = self.app.invoke(
            {
                "mode": "chat",
                "user": req.profile or S.UserProfile(user_id=req.user_id),
                "current_location": req.current_location,
                "question": req.question,
                "history": history,
            },
            config,
        )
        answer = result.get("final_answer", "")
        # 다음 질문의 지시어 해석("거기는?")에 쓰도록 이번 문답을 기록한다.
        self.app.update_state(config, {"history": [
            *history,
            {"role": "user", "content": req.question},
            {"role": "assistant", "content": answer},
        ]})
        return ChatResponse(
            conversation_id=conversation_id,
            answer=answer,
            selected_agents=result.get("selected_agents") or [],
            phase=result.get("phase") or S.Phase.NONE,
            used_fallback=bool(result.get("used_fallback")),
        )
