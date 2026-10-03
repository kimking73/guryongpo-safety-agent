"""사용자 기억(장기)을 실제 로컬 DB(ai_memory 스키마)에 저장 — AI 서버 재시작(서비스를 새로 만듦) 뒤에도 남는지.

실행: cd 코드/ai && .venv/bin/python -m pytest -m db -q   (docker compose의 db + 08_ai_memory.sh 계정 필요)
"""

import uuid

import psycopg
import pytest

import test_tools_db_live  # noqa: F401  루트 .env를 환경 변수로 읽어 둔다 (AI_MEM_DB_* 등)
from guardian_ai import graph as G
from guardian_ai import memory as M
from guardian_ai.llm import MemoryFact, MemoryUpdate
from guardian_ai.service import ChatRequest, ChatService, make_serde

pytestmark = pytest.mark.db
KNEE = MemoryUpdate(facts=[MemoryFact(field="walking_impaired", value="true", quote="무릎이 안 좋아요")],
                    summary="대피소를 물어봄")


def boot():
    """서버 시작과 같은 순서로 저장소를 만든다. DB에 못 닿으면 건너뛴다."""
    saver, store, backend = M.make_backends(make_serde())
    if backend != "postgres":
        pytest.skip("ai_memory DB에 접속할 수 없음 — docker compose up -d db, 08_ai_memory.sh 확인")
    return ChatService(classifier=G.keyword_classify, checkpointer=saver, store=store,
                       extractor=lambda q, a, known, summary="": KNEE)


def test_user_memory_survives_restart_but_conversation_does_not():
    user = f"test-{uuid.uuid4().hex[:8]}"
    svc = boot()
    first = svc.chat(ChatRequest(user_id=user, question="무릎이 안 좋아요. 대피소 어디예요?"))

    svc2 = boot()                                                       # 재시작 = 새 서비스, 같은 DB
    facts, episodes = M.load(svc2.store, user)
    assert facts["walking_impaired"]["value"] == "true" and episodes   # 사용자 기억(장기)은 남음
    again = svc2.chat(ChatRequest(user_id=user, question="거기까지 멀어요?", conversation_id=first.conversation_id))
    assert again.conversation_id != first.conversation_id              # 대화 기억(단기)은 서버 메모리라 새 대화
    M.forget(svc2.store, user)


def test_memory_account_cannot_touch_disaster_data():
    with psycopg.connect(M.mem_conninfo(), autocommit=True) as conn:
        assert conn.execute("SHOW search_path").fetchone()[0] == "ai_memory"
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute("SELECT count(*) FROM public.shelters")
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute("CREATE TABLE public.ai_probe(x int)")
