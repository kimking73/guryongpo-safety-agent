"""행동 권고 판단 로직을 실제로 끝까지 따라가는지 (실제 OpenAI·로컬 DB·경로 서버).

재난 단계와 '사용자 위치가 위험 영역 안인가'만 테스트가 정한다(시연 데이터로 재난 전·후를 만들 수 없어서).
분류(이동 가능·피해 유무 판정 포함)·근거 수집·작성·환각 검증은 실제로 돈다. 대화형 분기(질문 → 답 → 다음 분기)도 확인.

실행: cd 코드/ai && .venv/bin/python -m pytest tests/test_tree_live.py -m live -q -s   (질문 약 16개, OpenAI 수십 회, 10원 안팎)
필요: docker compose up -d (db·route·graphhopper), 루트 .env의 OPENAI_API_KEY·AI_DB_*·AI_MEM_DB_*
"""

import os
import time
import uuid

import pytest

from test_routing_live import _load_root_env

pytestmark = [pytest.mark.live, pytest.mark.db]
_load_root_env()
if not os.environ.get("OPENAI_API_KEY"):
    pytest.skip("OPENAI_API_KEY 없음", allow_module_level=True)

from guardian_ai import action as A  # noqa: E402
from guardian_ai import tools as T  # noqa: E402
from guardian_ai.service import ChatRequest, ChatService  # noqa: E402
from guardian_ai.state import Location, Phase, UserProfile  # noqa: E402

HERE = Location(lat=35.9907, lon=129.5526, label="현재 위치")
LOG: list[str] = []


@pytest.fixture
def make_service(monkeypatch):
    """재난 단계·위험 영역 판정만 고정한 실제 서비스."""
    def make(phase: Phase, inside: bool | None = True) -> ChatService:
        monkeypatch.setattr(A, "decide_phase", lambda state, fetch=None: phase)
        if inside is None:
            monkeypatch.setattr(T, "hazards_at", lambda lat, lon, fetch=None: {"available": False, "reason": "테스트"})
        else:
            monkeypatch.setattr(T, "hazards_at", lambda lat, lon, fetch=None:
                                {"available": True, "labels": "침수 경보" if inside else None})
        return ChatService()
    return make


def ask(svc, question, profile=None, conversation_id=None, remember=False, user_id=None):
    # 대화를 이어 갈 때는 같은 user_id여야 한다 (다른 사용자의 대화 id면 서버가 새 대화로 시작 — service._open_conversation)
    uid = user_id or (profile.user_id if profile is not None and profile.user_id != "p" else f"tree-{uuid.uuid4().hex[:8]}")
    t0 = time.perf_counter()
    res = svc.chat(ChatRequest(user_id=uid, question=question, current_location=HERE, conversation_id=conversation_id,
                               remember=remember, profile=profile or UserProfile(user_id=uid, age=40)),
                   **({"verified_uid": uid, "token": "live-test"} if remember else {}))
    LOG.append(f"[{res.decision_path}] {question} ({time.perf_counter() - t0:.0f}s, fallback={res.used_fallback}, "
               f"119={res.call_emergency}, route={(res.route.destination.name if res.route else None)})\n    {res.answer[:400]}")
    print(LOG[-1])
    assert not res.used_fallback, f"검증 실패로 안전 안내: {res.answer}"
    return res


def profile(**kw):
    return UserProfile(user_id=f"tree-{uuid.uuid4().hex[:8]}", **kw)


# --- 평시·재난 전 ------------------------------------------------------------------

def test_calm_info_question_has_no_advice(make_service):
    res = ask(make_service(Phase.NONE), "내일 비 와?")
    assert res.decision_path == "평시 > 정보 안내" and res.follow_up is None and "지금 할 일" not in res.answer


def test_calm_preparation_asks_dependents(make_service):
    res = ask(make_service(Phase.NONE), "태풍 대비는 어떻게 해야 해?")
    assert res.decision_path == "평시(대비) > 사용자 정보 확인"
    assert res.follow_up == A.QUESTIONS["dependents"] and res.answer.endswith(A.QUESTIONS["dependents"])
    assert "지금 할 일" in res.answer


def test_before_with_known_dependents_gives_checklist(make_service):
    res = ask(make_service(Phase.BEFORE), "태풍이 온다는데 뭘 준비해야 해?", profile(age=40, has_dependents=False))
    assert res.decision_path == "재난 전 > 체크리스트" and res.follow_up is None and "지금 할 일" in res.answer


def test_dependents_answer_continues_to_checklist(make_service):
    """질문 → 사용자 답 → 서버 프로필 반영 → 다음 질문에서 체크리스트 (대화형 분기). 서버 프로필은 가짜(test_memory.FakeWriter)"""
    from test_memory import FakeWriter
    svc = make_service(Phase.BEFORE)
    svc.writer = FakeWriter()
    svc.user_source = svc.writer.source
    uid = f"tree-{uuid.uuid4().hex[:8]}"
    first = ask(svc, "태풍 오기 전에 뭘 해야 해?", UserProfile(user_id=uid, age=40), remember=True, user_id=uid)
    assert first.follow_up == A.QUESTIONS["dependents"]
    ask(svc, "아니요, 혼자 살아서 함께 대피할 가족은 없어요.", UserProfile(user_id=uid, age=40),
        conversation_id=first.conversation_id, remember=True, user_id=uid)
    for _ in range(30):                                          # 프로필 반영은 답변 뒤 백그라운드
        if any("has_dependents" in fields for _, fields in svc.writer.calls):
            break
        time.sleep(1)
    svc.writer.profile["has_dependents"] = False                 # 가짜 서버: 받은 값을 프로필에 (FakeWriter 는 보행만 흉내)
    third = ask(svc, "그럼 태풍 준비는 뭘 하면 돼?", UserProfile(user_id=uid, age=40),
                conversation_id=first.conversation_id, remember=True, user_id=uid)
    assert third.decision_path == "재난 전 > 체크리스트", f"동반자 답이 반영되지 않음: {svc.writer.calls}"


# --- 재난 중 ---------------------------------------------------------------------

def test_during_outside_hazard_is_safe(make_service):
    res = ask(make_service(Phase.DURING, inside=False), "비가 많이 오는데 어떻게 해야 해?")
    assert res.decision_path == "재난 중 > 안전" and not res.call_emergency and res.follow_up is None


def test_during_inside_healthy_can_move_gets_route(make_service):
    res = ask(make_service(Phase.DURING), "비가 많이 오는데 어떻게 해야 해?", profile(age=30))
    assert res.decision_path == "재난 중 > 위험 지역 > 이동 가능" and res.route is not None and res.follow_up is None
    first_step = res.answer.split("지금 할 일:")[1].strip().splitlines()[0]
    assert res.route.destination.name in first_step, first_step       # 대피소 경로가 첫 번째 할 일


def test_during_trapped_is_119_first(make_service):
    res = ask(make_service(Phase.DURING), "집에 물이 차서 못 나가요. 어떻게 해요?", profile(age=50))
    assert res.decision_path == "재난 중 > 위험 지역 > 이동 불가능" and res.call_emergency
    assert res.answer.startswith(A.EMERGENCY_STEP)


def test_during_unknown_mobility_asks_then_follows_answer(make_service):
    """보행 불편 → 질문 → '걸어갈 수 있어요' → 이동 가능 / '못 움직여요' → 이동 불가능."""
    svc = make_service(Phase.DURING)
    old = profile(age=80, walking_impaired=True)
    first = ask(svc, "비가 많이 오는데 어떻게 해야 해?", old)
    assert first.decision_path == "재난 중 > 위험 지역 > 이동 가능 여부 확인" and first.follow_up == A.QUESTIONS["can_move"]
    assert first.route is not None                                       # 안내 + 질문: 경로도 함께
    yes = ask(svc, "네, 지팡이 짚고 천천히 걸어갈 수 있어요.", old, conversation_id=first.conversation_id)
    assert yes.decision_path == "재난 중 > 위험 지역 > 이동 가능"
    first2 = ask(svc, "비가 많이 오는데 어떻게 해야 해?", old)
    no = ask(svc, "아니요, 다리가 너무 아파서 혼자서는 못 움직여요.", old, conversation_id=first2.conversation_id)
    assert no.decision_path == "재난 중 > 위험 지역 > 이동 불가능" and no.call_emergency


def test_during_hazard_unknown_is_treated_as_danger(make_service):
    res = ask(make_service(Phase.DURING, inside=None), "지금 어떻게 해야 해?", profile(age=30))
    assert res.decision_path.startswith("재난 중 > 위험 지역")


# --- 재난 후 ---------------------------------------------------------------------

def test_after_asks_damage_then_branches(make_service):
    svc = make_service(Phase.AFTER)
    user = profile(age=40)
    first = ask(svc, "비가 그쳤는데 이제 뭘 해야 해?", user)
    assert first.decision_path == "재난 후 > 피해 확인" and first.follow_up == A.QUESTIONS["damage"]
    hit = ask(svc, "네, 집 1층에 물이 들어와서 침수됐어요.", user, conversation_id=first.conversation_id)
    assert hit.decision_path == "재난 후 > 피해 존재" and "확인되지 않음" in hit.answer   # 보험·법률·통제 도로
    user2 = profile(age=40)
    first2 = ask(svc, "태풍 지나갔는데 이제 뭐 하면 돼?", user2)
    ok = ask(svc, "다행히 피해는 없어요.", user2, conversation_id=first2.conversation_id)
    assert ok.decision_path == "재난 후 > 피해 없음" and ok.follow_up is None


def test_after_damage_stated_up_front(make_service):
    res = ask(make_service(Phase.AFTER), "태풍 때문에 창문이 깨지고 집이 파손됐어요. 어떻게 해야 해요?")
    assert res.decision_path == "재난 후 > 피해 존재" and res.follow_up is None


def teardown_module():
    print("\n==== 판단 로직 live 결과 ====\n" + "\n".join(LOG))
