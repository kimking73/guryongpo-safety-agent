"""대화 기억(단기)과 사용자 기억(장기) — 2026-10-02.

단기 기억 = LangGraph Checkpointer — InMemorySaver (사용자 결정 2026-10-02). 대화(thread_id = conversation_id) 안의
           그래프 상태 전체를 서버 메모리에만 둔다. 마지막 문답 후 CONVERSATION_TTL_MIN이 지나거나 서버가 재시작되면 사라진다
           (대화 만료·정리는 service.ChatService). 위치·건강 정보가 대화 기록째로 DB에 영구 저장되지 않는다.
장기 기억 = LangGraph Store — PostgresStore. 사용자(user_id)마다 대화를 넘어 남기는 것, 이름공간
           ("users", user_id, "facts")    사용자가 자기에 대해 직접 말한 사실 (예: 무릎이 불편함, 어선 보유)
           ("users", user_id, "episodes") 대화별 한 문장 요약
           db/init/08_ai_memory.sh가 만든 ai_memory 스키마에, 그 스키마만 쓸 수 있는 계정(AI_MEM_DB_*)으로 저장한다.
재난 데이터(위험 판정·관측값)는 기억하지 않는다 — 답변의 재난 정보는 항상 DB 최신값 (tools.py, 읽기 전용 계정).
DB에 닿지 않으면 장기 기억도 메모리 저장(InMemoryStore)으로 대체한다 — 그 경우 재시작하면 사라진다.
"""

from __future__ import annotations

import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Any

from langgraph.checkpoint.memory import InMemorySaver
from langgraph.store.base import BaseStore
from langgraph.store.memory import InMemoryStore

from .state import Mobility, UserProfile

logger = logging.getLogger(__name__)
KST = timezone(timedelta(hours=9))

CONNECT_TIMEOUT_S = 3
MAX_EPISODES = 5          # 새 대화에 넘기는 지난 대화 요약 수
# 마지막 문답 후 이 시간이 지난 대화는 끝난 것으로 본다: 단기 기억을 지우고, 같은 대화 id로 와도 새 대화로 시작한다
# (몇 시간 전의 "거기"로 지금 질문을 해석하지 않게 + 서버 메모리 정리). 사용자 기억(장기)은 그대로 이어진다.
CONVERSATION_TTL_MIN = 60

# 프로필로 옮길 수 있는 사실 → UserProfile 필드. 나머지(자주 가는 곳, 기타)는 참고 문장으로만 쓴다.
PROFILE_FIELDS = {"age", "walking_impaired", "has_dependents", "mobility", "occupation"}
FACT_LABELS = {
    "age": "나이", "walking_impaired": "보행 불편", "has_dependents": "보호가 필요한 동반자",
    "mobility": "이동수단", "occupation": "직업", "frequent_place": "자주 가는 곳", "note": "기타",
    "home_address": "집 주소",
}
# 장소 사실: 저장할 때 좌표를 찾아 함께 남긴다 (save(locate=…)) — 앱이 집 주소·내 장소로 지도에 넣는다 (2026-10-08)
PLACE_FIELDS = {"home_address", "frequent_place"}
# 하나만 두고 덮어쓰는 사실 (나머지 frequent_place·note 는 값마다 쌓인다)
SINGLE_FIELDS = PROFILE_FIELDS | {"home_address"}


def _facts_ns(user_id: str) -> tuple[str, ...]:
    return ("users", user_id, "facts")


def _episodes_ns(user_id: str) -> tuple[str, ...]:
    return ("users", user_id, "episodes")


# --- 저장소 만들기 ---------------------------------------------------------------

def mem_conninfo() -> str:
    """기억 저장 계정 접속 문자열. 호스트·포트·DB 이름은 읽기 전용 계정(db.py)과 같다."""
    from psycopg.conninfo import make_conninfo

    return make_conninfo(
        host=os.environ.get("AI_DB_HOST") or "localhost",
        port=os.environ.get("AI_DB_PORT") or os.environ.get("DB_HOST_PORT") or "5433",
        dbname=os.environ.get("DB_NAME") or "guardian",
        user=os.environ.get("AI_MEM_DB_USER") or "guardian_ai_mem",
        password=os.environ.get("AI_MEM_DB_PASSWORD") or "",
        connect_timeout=CONNECT_TIMEOUT_S,
        application_name="guardian_ai_memory",
    )


def make_backends(serde) -> tuple[Any, BaseStore, str]:
    """(checkpointer, store, 장기 기억 저장 방식).

    checkpointer(단기)는 항상 InMemorySaver. store(장기)는 PostgreSQL에 닿으면 PostgresStore, 아니면 InMemoryStore.
    serde: 체크포인트 직렬화기 (service.STATE_TYPES를 등록한 것 — 우리 타입을 복원할 때 경고·차단 방지).
    store 표는 처음 뜰 때 setup()이 ai_memory 스키마에 만든다 (재실행 안전).
    """
    saver = InMemorySaver(serde=serde)
    try:
        from langgraph.store.postgres import PostgresStore
        from psycopg.rows import dict_row
        from psycopg_pool import ConnectionPool

        pool = ConnectionPool(mem_conninfo(), min_size=1, max_size=5, timeout=CONNECT_TIMEOUT_S, open=False,
                              kwargs={"autocommit": True, "prepare_threshold": 0, "row_factory": dict_row},
                              name="guardian_ai_memory")
        pool.open(wait=True, timeout=CONNECT_TIMEOUT_S)
        store = PostgresStore(pool)
        store.setup()
        logger.info("사용자 기억 저장: PostgreSQL (ai_memory), 대화 기억: 서버 메모리")
        return saver, store, "postgres"
    except Exception as e:  # noqa: BLE001 — DB가 없어도 AI 서버는 떠야 한다
        logger.warning("사용자 기억 DB 연결 실패 → 메모리 저장 (재시작 시 소실): %s: %s", type(e).__name__, e)
        return saver, InMemoryStore(), "memory"


# --- 사용자 기억: 불러오기 -----------------------------------------------------------

def load(store: BaseStore, user_id: str) -> tuple[dict[str, dict], list[dict]]:
    """(사실 {key: value}, 최근 대화 요약 목록 — 최신순)."""
    facts = {it.key: it.value for it in store.search(_facts_ns(user_id), limit=100)}
    episodes = sorted((it.value for it in store.search(_episodes_ns(user_id), limit=100)),
                      key=lambda v: v.get("updated_at", ""), reverse=True)[:MAX_EPISODES]
    return facts, episodes


def apply_to_profile(profile: UserProfile, facts: dict[str, dict]) -> UserProfile:
    """앱이 보내지 않은(비어 있는) 프로필 칸만 기억으로 채운다. 앱이 보낸 값이 항상 우선."""
    update: dict[str, Any] = {}
    for key in PROFILE_FIELDS:
        f = facts.get(key)
        if f is None or getattr(profile, key) is not None:
            continue
        value = f.get("value")
        try:
            if key == "age":
                value = int(value)
            elif key in ("walking_impaired", "has_dependents"):
                value = str(value).lower() in ("true", "1", "yes", "예")
            elif key == "mobility":
                value = Mobility(value)
        except (TypeError, ValueError):
            continue
        update[key] = value
    return profile.model_copy(update=update) if update else profile


# 프로필 항목(나이·직업·집 등)은 서버 프로필이 기준이라 기억 문장에서 뺀다 (2026-10-08, 사용자 결정 — 프로필과 기억이 다를 때
# 근거끼리 어긋나지 않게). 기억은 앱을 거쳐 프로필로 넘어가는 통로 + 기타 메모·대화 요약을 맡는다
PROFILE_BACKED = PROFILE_FIELDS | {"home_address", "frequent_place"}


def memory_lines(facts: dict[str, dict], episodes: list[dict], include_profile_facts: bool = False) -> list[str]:
    """프롬프트·근거에 넣을 문장: 기타 메모 + 지난 대화 요약 (include_profile_facts 면 프로필 항목도 — 서버 프로필이 없을 때).
    사용자가 실제로 한 말(quote)을 같이 남겨 근거가 되게 한다."""
    lines = []
    for key, f in sorted(facts.items()):
        if not include_profile_facts and key.split(":", 1)[0] in PROFILE_BACKED:
            continue
        label = FACT_LABELS.get(key.split(":", 1)[0], "기타")
        quote = f" (사용자 말: \"{f['quote']}\")" if f.get("quote") else ""
        lines.append(f"{label}: {f.get('value')}{quote}")
    lines += [f"지난 대화({e.get('date', '')}): {e.get('summary', '')}" for e in episodes]
    return lines


# --- 사용자 기억: 저장하기 -----------------------------------------------------------

ALLOWED_FIELDS = set(FACT_LABELS)


def save(store: BaseStore, user_id: str, conversation_id: str, update, locate=None) -> int:
    """기억 추출 결과(llm.MemoryUpdate)를 저장한다. 저장한 사실 수를 돌려준다.

    사실 key: 프로필 필드는 그 이름(덮어씀 — 최신 발언이 우선), 자주 가는 곳·기타는 "frequent_place:<값>"·"note:<값>".
    """
    now = datetime.now(KST)
    saved = 0
    for f in update.facts:
        if f.field not in ALLOWED_FIELDS or not str(f.value).strip():
            continue
        key = f.field if f.field in SINGLE_FIELDS else f"{f.field}:{str(f.value).strip()[:40]}"
        item = {"value": str(f.value).strip(), "quote": f.quote.strip(),
                "conversation_id": conversation_id, "updated_at": now.isoformat()}
        if f.field in PLACE_FIELDS and locate is not None:
            try:
                where = locate(item["value"])
            except Exception:  # noqa: BLE001 — 좌표를 못 찾아도 글자로는 저장한다
                where = None
            if where:
                item.update(lat=where["lat"], lon=where["lon"], address=where.get("address") or where.get("name"))
        store.put(_facts_ns(user_id), key, item)
        saved += 1
    if update.summary.strip():
        store.put(_episodes_ns(user_id), conversation_id,
                  {"summary": update.summary.strip(), "date": f"{now:%m/%d}", "updated_at": now.isoformat()})
    return saved


def conversation_summary(store: BaseStore, user_id: str, conversation_id: str) -> str:
    """이 대화의 지금까지 요약 (이어지는 대화에서 요약을 덮어쓰지 않고 넓히기 위해)."""
    item = store.get(_episodes_ns(user_id), conversation_id)
    return item.value.get("summary", "") if item else ""


def export(store: BaseStore, user_id: str) -> dict[str, Any]:
    facts, episodes = load(store, user_id)
    return {"user_id": user_id, "facts": facts, "episodes": episodes}


def forget_fact(store: BaseStore, user_id: str, key: str) -> bool:
    """사실 하나 지우기 (앱 프로필의 'AI가 기억한 정보'에서 지울 때). 있었으면 True."""
    if store.get(_facts_ns(user_id), key) is None:
        return False
    store.delete(_facts_ns(user_id), key)
    return True


def forget(store: BaseStore, user_id: str) -> int:
    """사용자 기억(사실·대화 요약)을 모두 지운다. 지운 항목 수."""
    n = 0
    for ns in (_facts_ns(user_id), _episodes_ns(user_id)):
        for it in store.search(ns, limit=1000):
            store.delete(ns, it.key)
            n += 1
    return n
