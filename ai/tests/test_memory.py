"""대화 기억(단기)·사용자 기억(장기) — 메모리 저장소로 실행 (DB·LLM 없이)."""

import pytest

from guardian_ai import flood as F
from guardian_ai import graph as G
from guardian_ai import memory as M
from guardian_ai.llm import MemoryFact, MemoryUpdate, build_prompt
from guardian_ai.service import ChatRequest, ChatService
from guardian_ai.state import Location, Specialist, UserProfile
from guardian_ai.tools import route_profile

KNEE = MemoryUpdate(facts=[MemoryFact(field="walking_impaired", value="true", quote="제가 무릎이 안 좋아요"),
                           MemoryFact(field="frequent_place", value="구룡포시장", quote="시장에 자주 가요")],
                    summary="무릎이 불편하다며 대피소 가는 길을 물어봄")


class Spy:
    """분류기 대신: 받은 state를 기록하고 키워드 분류 결과를 돌려준다."""

    def __init__(self):
        self.states = []

    def __call__(self, state):
        self.states.append(state)
        return G.keyword_classify(state)


def service(extract=lambda q, a, known, summary="": KNEE, spy=None):
    return ChatService(classifier=spy or G.keyword_classify, extractor=extract)


def ask(svc, question, user="u1", **kw):
    return svc.chat(ChatRequest(user_id=user, question=question, **kw))


def test_new_conversation_recalls_facts_from_previous_one():
    spy = Spy()
    svc = service(spy=spy)
    first = ask(svc, "제가 무릎이 안 좋아요. 대피소 어디예요?")
    second = ask(svc, "비 오는데 어디로 가요?")                      # conversation_id 없음 = 새 대화
    assert second.conversation_id != first.conversation_id

    state = spy.states[-1]
    assert state["user"].walking_impaired is True                 # 기억 → 프로필
    assert route_profile(state["user"]) == "elderly"              # → 노약자 경로
    assert any("보행 불편" in m and "무릎" in m for m in state["user_memory"])
    assert any("지난 대화" in m and "대피소" in m for m in state["user_memory"])
    assert "이 사용자에 대해 기억하는 것" in build_prompt(state)  # 분류 프롬프트에 들어감


def test_profile_sent_by_app_wins_over_memory():
    spy = Spy()
    svc = service(spy=spy)
    ask(svc, "무릎이 안 좋아요")
    ask(svc, "비 와요?", profile=UserProfile(user_id="u1", walking_impaired=False))
    assert spy.states[-1]["user"].walking_impaired is False


def test_remember_off_neither_saves_nor_loads():
    calls = []
    spy = Spy()
    svc = service(extract=lambda *a: calls.append(a) or KNEE, spy=spy)
    ask(svc, "무릎이 안 좋아요", remember=False)
    assert calls == [] and M.export(svc.store, "u1")["facts"] == {}
    ask(svc, "무릎이 안 좋아요")                                     # 켜고 저장
    ask(svc, "비 와요?", remember=False)                             # 꺼진 대화는 불러오지도 않음
    assert spy.states[-1]["user_memory"] == [] and not spy.states[-1]["user"].walking_impaired


def test_other_users_conversation_id_starts_a_new_conversation():
    spy = Spy()
    svc = service(spy=spy)
    mine = ask(svc, "구룡포항 수위 알려줘", user="alice")
    theirs = ask(svc, "아까 뭐 물어봤지?", user="bob", conversation_id=mine.conversation_id)
    assert theirs.conversation_id != mine.conversation_id
    assert spy.states[-1]["history"] == []                           # alice의 대화 기록을 못 봄
    assert spy.states[-1]["user_memory"] == []                       # alice의 기억도 못 봄


def test_same_conversation_still_continues():
    spy = Spy()
    svc = service(spy=spy)
    first = ask(svc, "대피소 어디예요?")
    ask(svc, "거기까지 가는 길은요?", conversation_id=first.conversation_id)
    assert [m["role"] for m in spy.states[-1]["history"]] == ["user", "assistant"]


def test_continued_conversation_widens_its_summary_instead_of_replacing_it():
    seen = []

    def extract(q, a, known, summary=""):
        seen.append(summary)
        return MemoryUpdate(facts=[], summary=f"{summary} + {q}".strip(" +"))
    svc = service(extract=extract)
    first = ask(svc, "대피소 어디예요?")
    ask(svc, "거기까지 얼마나 걸려요?", conversation_id=first.conversation_id)
    assert seen == ["", "대피소 어디예요?"]                        # 두 번째 추출은 첫 요약을 받는다
    assert M.load(svc.store, "u1")[1][0]["summary"] == "대피소 어디예요? + 거기까지 얼마나 걸려요?"


def test_close_waits_for_pending_memory_saves():
    from concurrent.futures import ThreadPoolExecutor
    import time

    def slow(q, a, known, summary=""):
        time.sleep(0.2)
        return KNEE
    svc = ChatService(classifier=G.keyword_classify, extractor=slow, executor=ThreadPoolExecutor(1))
    ask(svc, "무릎이 안 좋아요")
    svc.close()                                                      # 종료 = 저장이 끝날 때까지 대기
    assert "walking_impaired" in M.export(svc.store, "u1")["facts"]


def test_conversation_expires_after_an_hour_of_silence_but_user_memory_stays():
    from datetime import datetime, timedelta, timezone
    clock = {"t": datetime(2026, 10, 2, 9, 0, tzinfo=timezone.utc)}
    spy = Spy()
    svc = ChatService(classifier=spy, extractor=lambda q, a, known, summary="": KNEE, now=lambda: clock["t"])
    first = ask(svc, "무릎이 안 좋아요. 대피소 어디예요?")

    clock["t"] += timedelta(minutes=30)                              # 1시간 안 → 같은 대화
    assert ask(svc, "거기까지 멀어요?", conversation_id=first.conversation_id).conversation_id == first.conversation_id

    clock["t"] += timedelta(minutes=61)                              # 마지막 문답 후 1시간 넘음 → 새 대화
    later = ask(svc, "거기 지금 가도 돼요?", conversation_id=first.conversation_id)
    assert later.conversation_id != first.conversation_id
    assert spy.states[-1]["history"] == []                           # 옛 대화의 "거기"는 모름
    assert spy.states[-1]["user"].walking_impaired is True           # 사용자 기억은 이어짐
    old = svc.app.get_state({"configurable": {"thread_id": first.conversation_id}}).values
    assert not old                                                   # 만료된 대화는 메모리에서 지움


def test_unknown_conversation_id_starts_new_one():
    """서버 재시작 뒤처럼 메모리에 없는 대화 id → 새 대화 (남은 기록이 없으니 이어 갈 수 없다)."""
    res = ask(service(), "대피소 어디예요?", conversation_id="from-before-restart")
    assert res.conversation_id != "from-before-restart"


def test_extractor_failure_does_not_break_the_answer():
    def broken(*a):
        raise TimeoutError("LLM 응답 없음")
    res = ask(service(extract=broken), "무릎이 안 좋아요")
    assert res.answer and not res.used_fallback


def test_memory_becomes_evidence_so_mentions_are_not_flagged():
    from test_flood_verify import heavy_rain_db
    out = F.make_rain_flood_agent(fetch=heavy_rain_db)({
        "mode": "chat", "question": "비 와요?", "user": UserProfile(user_id="u1", home=Location(lat=35.99, lon=129.556)),
        "user_memory": ["보행 불편: true (사용자 말: \"무릎이 안 좋아요\")"]})
    ev = out["specialist_results"][0].evidence
    assert any(e.source == "user_memory" and "무릎" in str(e.value) for e in ev)


def test_profile_fact_is_overwritten_and_places_accumulate():
    svc = service()
    M.save(svc.store, "u1", "c1", KNEE)
    M.save(svc.store, "u1", "c2", MemoryUpdate(
        facts=[MemoryFact(field="walking_impaired", value="false", quote="이제 다 나았어요"),
               MemoryFact(field="frequent_place", value="구룡포항", quote="항구에도 가요")], summary="안부"))
    facts, episodes = M.load(svc.store, "u1")
    assert facts["walking_impaired"]["value"] == "false"             # 최신 발언이 우선
    assert {"frequent_place:구룡포시장", "frequent_place:구룡포항"} <= set(facts)
    assert len(episodes) == 2


def test_export_and_forget():
    svc = service()
    M.save(svc.store, "u1", "c1", KNEE)
    assert set(M.export(svc.store, "u1")["facts"]) == {"walking_impaired", "frequent_place:구룡포시장"}
    assert M.forget(svc.store, "u1") == 3                            # 사실 2 + 요약 1
    assert M.export(svc.store, "u1") == {"user_id": "u1", "facts": {}, "episodes": []}


@pytest.mark.parametrize("field, value, expect", [
    ("age", "72", 72), ("age", "칠십", None), ("mobility", "wheelchair", "wheelchair"), ("has_dependents", "true", True)])
def test_profile_conversion(field, value, expect):
    p = M.apply_to_profile(UserProfile(user_id="u1"), {field: {"value": value}})
    got = getattr(p, field)
    assert (got.value if hasattr(got, "value") else got) == expect


def test_rain_flood_route_agent_selection_unchanged():
    spy = Spy()
    ask(service(spy=spy), "비 오는데 걸어서 집에 가도 되나요?")
    assert set(G.keyword_classify(spy.states[-1])) == {Specialist.RAIN_FLOOD, Specialist.LOCATION_ROUTE}
