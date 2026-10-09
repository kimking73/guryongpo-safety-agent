"""대화 기억(단기)과 대화 내용 → 서버 프로필 반영 (DB·LLM 없이, 2026-10-08: 사용자 정보는 서버 프로필 하나만)."""

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
import time

from guardian_ai import graph as G
from guardian_ai.llm import MemoryFact, MemoryUpdate
from guardian_ai.service import ChatRequest, ChatService
from guardian_ai.state import Specialist, UserProfile

AGE = MemoryUpdate(facts=[MemoryFact(field="age", value="72", quote="저는 72살이에요")])


class Spy:
    """분류기 대신: 받은 state를 기록하고 키워드 분류 결과를 돌려준다."""

    def __init__(self):
        self.states = []

    def __call__(self, state):
        self.states.append(state)
        return G.keyword_classify(state)


class FakeWriter:
    """서버 프로필 대신: 반영 요청을 기록하고, 그 값을 user_source 가 돌려준다 (서버 왕복 흉내)"""

    def __init__(self):
        self.calls, self.profile = [], {}

    def apply(self, token, facts, today=None):
        self.calls.append((token, [f.field for f in facts]))
        for f in facts:
            if f.field == "age":
                self.profile["age"] = int(f.value)
        return {"profile": dict(self.profile), "places": []}

    def source(self, uid):
        return {"available": True, "profile": dict(self.profile)}


def service(extract=lambda q, a, known, summary="": AGE, spy=None, **kw):
    svc = ChatService(classifier=spy or G.keyword_classify, extractor=extract, **kw)
    svc.writer = FakeWriter()
    svc.user_source = svc.writer.source
    return svc


def ask(svc, question, user="u1", signed_in=True, **kw):
    extra = {"verified_uid": user, "token": f"tok-{user}"} if signed_in else {}
    return svc.chat(ChatRequest(user_id=user, question=question, **kw), **extra)


def test_what_user_said_goes_to_server_profile_and_next_question_reads_it():
    spy = Spy()
    svc = service(spy=spy)
    ask(svc, "저는 72살이에요. 대피소 어디예요?")
    assert svc.writer.calls == [("tok-u1", ["age"])]                        # 본인 토큰으로 서버 프로필 수정
    ask(svc, "비 와요?")                                                    # 새 대화도 서버 프로필에서 읽음
    assert spy.states[-1]["user"].age == 72
    assert spy.states[-1]["user_memory"] == []                              # 예전 장기 기억 문장은 쓰지 않음


def test_not_signed_in_neither_reads_nor_writes_profile():
    spy = Spy()
    svc = service(spy=spy)
    svc.writer.profile["age"] = 72
    ask(svc, "저는 72살이에요", signed_in=False)
    assert svc.writer.calls == [] and spy.states[-1]["user"].age is None


def test_remember_off_does_not_write():
    svc = service()
    ask(svc, "저는 72살이에요", remember=False)
    assert svc.writer.calls == []


def test_nothing_said_about_self_writes_nothing():
    svc = service(extract=lambda *a, **k: MemoryUpdate(facts=[]))
    ask(svc, "대피소 어디예요?")
    assert svc.writer.calls == []


def test_server_profile_wins_over_app_values_and_app_fills_gaps():
    spy = Spy()
    svc = service(spy=spy)
    svc.writer.profile.update(age=80)
    ask(svc, "대피소", profile=UserProfile(user_id="u1", age=70, occupation="자영업자"))
    u = spy.states[-1]["user"]
    assert u.age == 80 and u.occupation == "자영업자"


def test_extractor_is_told_the_current_profile():
    seen = []
    svc = service(extract=lambda q, a, known, summary="": seen.append(known) or MemoryUpdate(facts=[]))
    svc.writer.profile.update(age=72)
    ask(svc, "대피소 어디예요?")
    assert seen == [["나이: 72"]]


def test_other_users_conversation_id_starts_a_new_conversation():
    spy = Spy()
    svc = service(spy=spy)
    mine = ask(svc, "구룡포항 수위 알려줘", user="alice")
    theirs = ask(svc, "아까 뭐 물어봤지?", user="bob", conversation_id=mine.conversation_id)
    assert theirs.conversation_id != mine.conversation_id
    assert spy.states[-1]["history"] == []                           # alice의 대화 기록을 못 봄


def test_same_conversation_still_continues():
    spy = Spy()
    svc = service(spy=spy)
    first = ask(svc, "대피소 어디예요?")
    ask(svc, "거기까지 가는 길은요?", conversation_id=first.conversation_id)
    assert [m["role"] for m in spy.states[-1]["history"]] == ["user", "assistant"]


def test_close_waits_for_pending_profile_writes():
    def slow(q, a, known, summary=""):
        time.sleep(0.2)
        return AGE
    svc = service(extract=slow, executor=ThreadPoolExecutor(1))
    ask(svc, "저는 72살이에요")
    svc.close()                                                      # 종료 = 반영이 끝날 때까지 대기
    assert svc.writer.calls


def test_conversation_expires_after_an_hour_of_silence_but_profile_stays():
    clock = {"t": datetime(2026, 10, 2, 9, 0, tzinfo=timezone.utc)}
    spy = Spy()
    svc = service(spy=spy, now=lambda: clock["t"])
    first = ask(svc, "저는 72살이에요. 대피소 어디예요?")

    clock["t"] += timedelta(minutes=30)                              # 1시간 안 → 같은 대화
    assert ask(svc, "거기까지 멀어요?", conversation_id=first.conversation_id).conversation_id == first.conversation_id

    clock["t"] += timedelta(minutes=61)                              # 마지막 문답 후 1시간 넘음 → 새 대화
    later = ask(svc, "거기 지금 가도 돼요?", conversation_id=first.conversation_id)
    assert later.conversation_id != first.conversation_id
    assert spy.states[-1]["history"] == []                           # 옛 대화의 "거기"는 모름
    assert spy.states[-1]["user"].age == 72                          # 프로필은 이어짐
    old = svc.app.get_state({"configurable": {"thread_id": first.conversation_id}}).values
    assert not old                                                   # 만료된 대화는 메모리에서 지움


def test_unknown_conversation_id_starts_new_one():
    """서버 재시작 뒤처럼 메모리에 없는 대화 id → 새 대화 (남은 기록이 없으니 이어 갈 수 없다)."""
    res = ask(service(), "대피소 어디예요?", conversation_id="from-before-restart")
    assert res.conversation_id != "from-before-restart"


def test_extractor_or_server_failure_does_not_break_the_answer():
    def broken(*a, **k):
        raise TimeoutError("LLM 응답 없음")
    assert ask(service(extract=broken), "무릎이 안 좋아요").answer
    svc = service()
    svc.writer.apply = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("api 503"))
    assert ask(svc, "무릎이 안 좋아요").answer


def test_rain_flood_route_agent_selection_unchanged():
    spy = Spy()
    ask(service(spy=spy), "비 오는데 걸어서 집에 가도 되나요?")
    assert set(G.keyword_classify(spy.states[-1])) == {Specialist.RAIN_FLOOD, Specialist.LOCATION_ROUTE}
