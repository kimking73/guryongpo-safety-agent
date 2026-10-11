"""B5: 카드형 필드, 다듬기 → 환각 검증(숫자·내용), 실패 사유를 다시 다듬기에 전달, 응답 시간 (DB·LLM 없이)."""

from guardian_ai import graph as G
from guardian_ai import polish as P
from guardian_ai.service import ChatRequest, ChatService
from guardian_ai.state import (ActionPlan, CheckResult, Evidence, Location, Phase, RiskLevel, Specialist,
                               SpecialistResult)
from guardian_ai.verify import make_hallucination_check

HERE = Location(lat=35.9907, lon=129.5526, label="현재 위치")
EV = [Evidence(source="risk_assessments", key="침수 위험 단계", value="경보"),
      Evidence(source="observations", key="구룡포환승센터 침수심", value=230.0, unit="mm"),
      Evidence(source="observations", key="구룡포 AWS 1시간 강수량", value=38.5, unit="mm")]
LONG = "현재 위치는 침수 경보 단계입니다. 구룡포환승센터 침수심은 230mm, 1시간 강수량은 38.5mm입니다. " * 12


def flood_node(summary=LONG):
    return lambda s: {"specialist_results": [SpecialistResult(agent=Specialist.RAIN_FLOOD, summary=summary,
                                                              risk_level=RiskLevel.WARNING, evidence=EV)]}


def svc(**nodes):
    return ChatService(classifier=G.keyword_classify, overrides={Specialist.RAIN_FLOOD.value: flood_node(), **nodes})


def ask(service, q="비 와요?"):
    return service.chat(ChatRequest(user_id="u1", question=q, current_location=HERE))


# --- 내용 검사 ---------------------------------------------------------------------

def test_check_failure_is_retried_with_feedback_and_user_words_are_evidence():
    seen = []

    def checker(draft, evidence):
        seen.append(evidence)
        ok = len(seen) > 1
        return CheckResult(ok=ok, feedback="" if ok else "근거와 다른 내용: 없는 특보를 말함")
    feedbacks = []

    def manager_spy(state):
        feedbacks.append(state.get("manager_feedback"))
        return G.make_manager(G.keyword_classify)(state)
    res = ask(svc(**{G.HALLUCINATION_CHECK: make_hallucination_check(checker=checker),
                     G.MANAGER: manager_spy}), "내일 비 와요?")
    assert not res.used_fallback and len(seen) == 2
    assert "근거와 다른 내용" in (feedbacks[1] or "")                    # 실패 사유가 관리자에게 전달된다
    assert "사용자 질문: 내일 비 와요?" in seen[0]                         # 사용자가 한 말도 근거


# --- 카드 -----------------------------------------------------------------------

def test_card_takes_values_from_evidence_and_plan():
    state = {"specialist_results": [SpecialistResult(agent=Specialist.RAIN_FLOOD, summary="x", risk_level=RiskLevel.WARNING,
                                                     evidence=EV)],
             "action_plan": ActionPlan(phase=Phase.DURING, risk_level=RiskLevel.WARNING, steps=["대피하세요."],
                                       decision_path=["재난 중", "위험 지역", "이동 가능"], call_emergency=False,
                                       evidence=[Evidence(source="action_guides", key="행동요령: 호우", value="...")])}
    card = P.build_card(state)
    assert card["headline"] == "재난 중 · 위험 지역 · 이동 가능 · 호우·침수 경보"
    assert card["chips"][:3] == [{"label": "침수", "value": "경보"}, {"label": "침수심", "value": "230mm"},
                                 {"label": "1시간 강수량", "value": "38.5mm"}]
    assert card["steps"] == ["대피하세요."] and "행동요령(포항시 재난안전)" in card["sources"]


# --- 다듬기·재검증 -------------------------------------------------------------------

def test_short_draft_skips_polisher_but_gets_voice_and_card():
    called = []
    res = ask(svc(**{Specialist.RAIN_FLOOD.value: flood_node("침수 경보입니다."),
                     G.POLISH: P.make_polish(polisher=lambda *a: called.append(1) or ("x", "y"))}))
    assert called == [] and res.voice_text and res.card is not None and res.card.chips


def test_polisher_changing_a_number_gets_feedback_then_answer_goes_out_marked():
    """다듬기가 숫자를 바꾸면 환각 검증에서 걸리고, 사유가 다음 다듬기에 전달된다. 그래도 틀리면 만든 답을 그대로 보내고 used_fallback으로 표시한다."""
    feedbacks = []

    def bad_polisher(draft, summarize, feedback):
        feedbacks.append(feedback)
        return draft.replace("230mm", "300mm"), "침수심 300mm입니다."
    res = ask(svc(**{G.POLISH: P.make_polish(polisher=bad_polisher)}))
    assert feedbacks[0] == "" and "300" in feedbacks[1]
    assert res.used_fallback and "300mm" in res.answer and res.voice_text == "침수심 300mm입니다."


def test_polisher_fixed_on_retry_is_used():
    """첫 다듬기가 숫자를 바꿨어도 다시 돌 때 고치면 그 답이 나간다."""
    n = []

    def polisher(draft, summarize, feedback):
        n.append(feedback)
        return ("침수 경보입니다. 침수심은 300mm입니다." if len(n) == 1 else "침수 경보입니다. 침수심은 230mm입니다."), "침수 경보입니다."
    res = ask(svc(**{G.POLISH: P.make_polish(polisher=polisher)}))
    assert not res.used_fallback and res.answer == "침수 경보입니다. 침수심은 230mm입니다." and len(n) == 2


def test_good_polish_is_used_and_long_draft_asks_for_summary():
    seen = []

    def polisher(draft, summarize, feedback):
        seen.append(summarize)
        return "침수 경보입니다. 침수심은 230mm입니다.", "침수 경보입니다."
    res = ask(svc(**{G.POLISH: P.make_polish(polisher=polisher)}))
    assert res.answer == "침수 경보입니다. 침수심은 230mm입니다." and res.voice_text == "침수 경보입니다." and seen == [True]


def test_response_has_timings():
    res = ask(svc())
    assert res.timings["total"] >= 0 and "manager" in res.timings and "action_advisor" in res.timings
