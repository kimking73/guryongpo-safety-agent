"""채팅 서비스: 앱 요청 → 그래프 실행 → 응답.

HTTP 창구는 api.py, 이 파일은 요청·응답 형식과 기억을 맡는다.
- 단기 기억(대화 안): checkpointer(InMemorySaver), thread_id = conversation_id. 마지막 문답 후 1시간이 지나면 지운다
- 장기 기억(사용자별, 대화를 넘어): store — 새 대화마다 불러와 프로필·프롬프트에 넣고, 응답 뒤 백그라운드로 갱신 (memory.py)
"""

from __future__ import annotations

import logging
import threading
import uuid
from concurrent.futures import Executor, ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from typing import Callable

from langgraph.checkpoint.memory import InMemorySaver
from langgraph.checkpoint.serde.jsonplus import JsonPlusSerializer
from pydantic import BaseModel, Field

from . import graph as G
from . import memory as M
from . import state as S

logger = logging.getLogger(__name__)

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
    # 사용자 기억(대화를 넘어 남기는 사실)을 불러오고 저장할지. 기본 켜짐(사용자 결정 2026-10-02) —
    # 앱에 "기억 끄기·지우기"를 두고, 정식 서비스 전 동의 화면을 붙인다.
    remember: bool = True


class ChatResponse(BaseModel):
    """AI → 앱. 카드형 답변(수치 칩·할 일·출처)은 B5 다듬기에서 확장한다."""
    conversation_id: str
    answer: str
    selected_agents: list[S.Specialist] = Field(default_factory=list)
    phase: S.Phase = S.Phase.NONE
    used_fallback: bool = False


def make_serde() -> JsonPlusSerializer:
    return JsonPlusSerializer(allowed_msgpack_modules=STATE_TYPES)


def make_checkpointer() -> InMemorySaver:
    """대화 기억(단기) — 서버 메모리. 재시작하면 사라진다 (서비스도 M.make_backends()에서 같은 것을 쓴다)."""
    return InMemorySaver(serde=make_serde())


class _Inline(Executor):
    """테스트용: 백그라운드 대신 바로 실행."""
    def submit(self, fn, *args, **kwargs):
        from concurrent.futures import Future
        f: Future = Future()
        try:
            f.set_result(fn(*args, **kwargs))
        except Exception as e:  # noqa: BLE001
            f.set_exception(e)
        return f


class ChatService:
    def __init__(self, classifier: G.Classifier | None = None, checkpointer=None,
                 overrides: dict[str, G.Node] | None = None, store=None, extractor=None,
                 executor: Executor | None = None, now: Callable[[], datetime] | None = None):
        """classifier를 안 주면 실제 서비스 구성: OpenAI 분류기 + 실제 DB를 읽는 침수 agent(B3)
        + 위치·경로 agent(대피소·경로) + 숫자·내용 환각 검증 + PostgreSQL 기억(단기·장기) + 기억 추출기 (OPENAI_API_KEY, AI_DB_*, AI_MEM_DB_* 필요).
        classifier를 주면(테스트) 나머지 노드는 stub 그대로, 기억은 메모리 저장, 추출기 없음(넘기면 바로 실행).
        """
        nodes: dict[str, G.Node] = {}
        self.memory_backend = "memory"
        if classifier is None:
            # 키가 없는 테스트 환경에서 import 오류를 피하려고 여기서 import 한다
            from .flood import make_rain_flood_agent
            from .location import make_location_route_agent
            from .llm import OpenAIClassifier, OpenAIFactChecker, OpenAILocationWriter, OpenAIWriter
            from .verify import make_hallucination_check
            from .llm import OpenAIMemoryExtractor
            classifier = OpenAIClassifier()
            checkpointer, store, self.memory_backend = M.make_backends(make_serde())
            extractor = OpenAIMemoryExtractor()
            executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="memory")
            nodes = {
                S.Specialist.RAIN_FLOOD.value: make_rain_flood_agent(writer=OpenAIWriter()),
                S.Specialist.LOCATION_ROUTE.value: make_location_route_agent(writer=OpenAILocationWriter()),
                G.HALLUCINATION_CHECK: make_hallucination_check(checker=OpenAIFactChecker()),
            }
        self.app = G.build_graph(
            {G.MANAGER: G.make_manager(classifier), **nodes, **(overrides or {})},
            checkpointer=checkpointer or make_checkpointer(),
        )
        self.store = store if store is not None else M.InMemoryStore()
        self.extractor = extractor
        self.executor = executor or _Inline()
        # 진행 중인 대화: conversation_id → (주인 user_id, 마지막 문답 시각). 단기 기억과 같이 메모리에만 있다.
        self._active: dict[str, tuple[str, datetime]] = {}
        self._lock = threading.Lock()
        self._now = now or (lambda: datetime.now(timezone.utc))

    def _open_conversation(self, requested: str | None, user_id: str) -> str:
        """이어 갈 대화 id를 정한다. 만료된 대화는 단기 기억을 지운다.

        새 대화로 시작하는 경우: id가 없음 / 진행 중이 아님(만료·서버 재시작) / 다른 사용자의 대화(남의 기억을 읽지 못하게).
        """
        now, ttl = self._now(), timedelta(minutes=M.CONVERSATION_TTL_MIN)
        with self._lock:
            for cid, (_, last) in list(self._active.items()):     # 만료된 대화 정리 (서버 메모리 회수)
                if now - last > ttl:
                    self._active.pop(cid)
                    self.app.checkpointer.delete_thread(cid)
            owner = self._active.get(requested or "")
            if owner is not None and owner[0] == user_id:
                cid = requested
            else:
                if owner is not None:
                    logger.warning("다른 사용자의 대화 id로 요청 → 새 대화로 시작 (user=%s)", user_id)
                cid = uuid.uuid4().hex
            self._active[cid] = (user_id, now)
        return cid

    def chat(self, req: ChatRequest) -> ChatResponse:
        conversation_id = self._open_conversation(req.conversation_id, req.user_id)
        config = {"configurable": {"thread_id": conversation_id}}
        history = self.app.get_state(config).values.get("history", [])

        profile = req.profile or S.UserProfile(user_id=req.user_id)
        memory: list[str] = []
        if req.remember:
            try:
                facts, episodes = M.load(self.store, req.user_id)
                profile = M.apply_to_profile(profile, facts)
                memory = M.memory_lines(facts, episodes)
            except Exception:  # noqa: BLE001 — 기억을 못 읽어도 답은 한다
                logger.exception("사용자 기억 불러오기 실패")

        result = self.app.invoke(
            {
                "mode": "chat",
                "user": profile,
                "current_location": req.current_location,
                "question": req.question,
                "history": history,
                "user_memory": memory,
            },
            config,
        )
        answer = result.get("final_answer", "")
        if req.remember and self.extractor is not None:
            self.executor.submit(self._remember, req.user_id, conversation_id, req.question, answer, memory)
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

    def close(self) -> None:
        """서버 종료 때: 백그라운드 기억 저장이 끝날 때까지 기다린다 (재시작 직전 대화의 기억이 사라지지 않게)."""
        self.executor.shutdown(wait=True)

    def _remember(self, user_id: str, conversation_id: str, question: str, answer: str, known: list[str]) -> None:
        """응답 뒤 백그라운드: 이번 문답에서 사용자 사실·대화 요약을 뽑아 장기 기억에 저장. 실패는 로그만."""
        try:
            update = self.extractor(question, answer, known,
                                    M.conversation_summary(self.store, user_id, conversation_id))
            n = M.save(self.store, user_id, conversation_id, update)
            logger.info("사용자 기억 갱신 user=%s 사실 %d건 요약 '%s'", user_id, n, update.summary[:40])
        except Exception:  # noqa: BLE001
            logger.exception("사용자 기억 저장 실패")
