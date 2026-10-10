"""관리자 agent (B2): alert 라우팅 규칙, 대화 간 초기화, 분류기 장애 대체, OpenAI 분류기 호출 형태."""

from datetime import datetime
from types import SimpleNamespace

import pytest

from guardian_ai import graph as G
from guardian_ai.llm import Classification, OpenAIClassifier, build_prompt
from guardian_ai.service import ChatRequest, ChatService
from guardian_ai.state import (
    CheckResult,
    DisasterType,
    Location,
    RiskEvent,
    RiskLevel,
    Specialist,
    UserProfile,
)

USER = UserProfile(user_id="u1")


def alert(disaster: DisasterType, level: RiskLevel = RiskLevel.WARNING) -> dict:
    event = RiskEvent(disaster=disaster, level=level, location=Location(lat=35.99, lon=129.556),
                      issued_at=datetime(2026, 9, 24, 20, 0))
    return {"mode": "alert", "user": USER, "risk_event": event}


# --- code_check_list.md 1번: alert 모드 라우팅 ---------------------------------

@pytest.mark.parametrize("disaster, expected", [
    (DisasterType.LANDSLIDE, [Specialist.LANDSLIDE, Specialist.LOCATION_ROUTE]),
    (DisasterType.HEAVY_RAIN, [Specialist.RAIN_FLOOD, Specialist.LOCATION_ROUTE]),
    (DisasterType.FLOOD, [Specialist.RAIN_FLOOD, Specialist.LOCATION_ROUTE]),
    (DisasterType.STRONG_WIND, [Specialist.WIND_TYPHOON, Specialist.LOCATION_ROUTE]),
    (DisasterType.TYPHOON, [Specialist.WIND_TYPHOON, Specialist.LOCATION_ROUTE]),
    (DisasterType.FINE_DUST, [Specialist.LIFE_SAFETY]),
    (DisasterType.UV, [Specialist.LIFE_SAFETY]),
])
def test_alert_routes_each_disaster_to_its_agent(disaster, expected):
    assert G.manager(alert(disaster))["selected_agents"] == expected


def test_alert_advisory_does_not_add_route_agent():
    assert G.manager(alert(DisasterType.FLOOD, RiskLevel.ADVISORY))["selected_agents"] == [Specialist.RAIN_FLOOD]


def test_alert_critical_also_adds_route_agent():
    # DB 5단계 중 최고(critical)도 경보 이상 → 대피 경로 필요
    assert G.manager(alert(DisasterType.FLOOD, RiskLevel.CRITICAL))["selected_agents"] == \
        [Specialist.RAIN_FLOOD, Specialist.LOCATION_ROUTE]
    assert G.manager(alert(DisasterType.HIGH_SEAS, RiskLevel.WARNING))["selected_agents"] == [Specialist.WIND_TYPHOON]


def test_alert_does_not_call_classifier():
    def boom(state):
        raise AssertionError("alert 모드에서 분류기를 부르면 안 됨")
    G.make_manager(boom)(alert(DisasterType.TYPHOON))


# --- code_check_list.md 2번: 같은 대화의 다음 질문에 이전 값이 넘어가지 않음 -----------

def test_conversation_turns_do_not_share_retry_state():
    """매 질문마다 환각 검증이 한 번 실패한 뒤 통과. 이전에는 3번째 질문이 fallback이 됐다."""
    seen = []

    def fail_once_per_question(state):
        seen.append(state["question"])
        return {"checks": {"hallucination": CheckResult(ok=seen.count(state["question"]) > 1, feedback="수위 불일치")}}

    feedback_seen = []

    def spy_classify(state):
        feedback_seen.append((state["question"], state.get("manager_feedback")))
        return G.keyword_classify(state)

    service = ChatService(classifier=spy_classify)
    service.app = G.build_graph(
        {G.MANAGER: G.make_manager(spy_classify), G.HALLUCINATION_CHECK: fail_once_per_question},
        checkpointer=service.app.checkpointer,
    )
    conv = None
    for q in ["비 와요?", "태풍 와요?", "미세먼지 어때요?"]:
        res = service.chat(ChatRequest(user_id="u1", question=q, conversation_id=conv))
        conv = res.conversation_id
        assert not res.used_fallback, q

    # 새 질문의 첫 분류에는 이전 질문의 실패 사유가 없어야 하고, 재시도에는 있어야 한다
    firsts = {}
    for q, fb in feedback_seen:
        firsts.setdefault(q, fb)
    assert all(not fb for fb in firsts.values())
    assert any(fb for _, fb in feedback_seen)


def test_history_is_kept_between_turns():
    prompts = []

    def spy(state):
        prompts.append(state.get("history") or [])
        return []

    service = ChatService(classifier=spy)
    first = service.chat(ChatRequest(user_id="u1", question="구룡포항 근처에 있어요"))
    service.chat(ChatRequest(user_id="u1", question="거기 지금 위험해요?", conversation_id=first.conversation_id))
    assert prompts[0] == []
    assert prompts[1][0] == {"role": "user", "content": "구룡포항 근처에 있어요"}


# --- code_check_list.md 4번: 대화 기억 저장·복원 시 미등록 타입 경고 없음 ----------------

def test_checkpointer_restores_state_types_without_warnings(caplog):
    service = ChatService(classifier=G.keyword_classify)
    first = service.chat(ChatRequest(user_id="u1", question="비 와요?",
                                     profile=UserProfile(user_id="u1", age=70)))
    service.chat(ChatRequest(user_id="u1", question="태풍은요?", conversation_id=first.conversation_id))

    restored = service.app.get_state({"configurable": {"thread_id": first.conversation_id}}).values
    assert isinstance(restored["user"], UserProfile)
    assert "unregistered type" not in caplog.text


# --- 분류기 장애 대체 -----------------------------------------------------------

def test_classifier_failure_falls_back_to_keywords():
    def broken(state):
        raise TimeoutError("LLM 응답 없음")
    out = G.make_manager(broken)({"mode": "chat", "user": USER, "question": "태풍 오면 배는 어떻게 해요?"})
    assert out["selected_agents"] == [Specialist.WIND_TYPHOON]


# --- OpenAI 분류기: 실제 호출 없이 요청 형태와 결과 처리만 확인 ---------------------------

class FakeResponses:
    def __init__(self, parsed):
        self.parsed, self.calls = parsed, []

    def parse(self, **kwargs):
        self.calls.append(kwargs)
        return SimpleNamespace(output_parsed=self.parsed, output_text="...")


def fake_classifier(parsed) -> OpenAIClassifier:
    return OpenAIClassifier(client=SimpleNamespace(responses=FakeResponses(parsed)), model="test-model")


def test_user_info_only_statement_gets_confirmation_not_risk_or_checklist():
    """묻는 것 없이 자기 정보만 말하면: agent 없음 → 들은 내용만 되짚어 확인. 이전 턴의 카드·되묻기는 비운다 (2026-10-10)."""
    from guardian_ai.state import ActionPlan, Phase, RiskLevel
    clf = fake_classifier(Classification(agents=[], reason="자기 정보", wants_action=False, user_info="72세, 어업"))
    prev = {"mode": "chat", "user": USER, "question": "저는 72살이고 어업을 해요", "card": {"headline": "이전 카드"},
            "action_plan": ActionPlan(phase=Phase.DURING, risk_level=RiskLevel.WARNING, steps=["이전 할 일"])}
    out = G.make_manager(clf)(prev)
    assert out["selected_agents"] == [] and out["user_info"] == "72세, 어업" and out["wants_action"] is False
    assert G.route_specialists({**prev, **out}) == G.DIRECT_REPLY
    reply = G.direct_reply({**prev, **out})
    assert reply["final_answer"] == G.USER_INFO_REPLY.format(info="72세, 어업")
    assert "위험" not in reply["final_answer"] and "할 일" not in reply["final_answer"]
    assert reply["card"] is None and reply["action_plan"] is None


def test_manager_passes_wants_action_and_drops_user_info_when_agents_are_selected():
    clf = fake_classifier(Classification(agents=[Specialist.RAIN_FLOOD], reason="비", wants_action=False, user_info="72세"))
    out = G.make_manager(clf)({"mode": "chat", "user": USER, "question": "72살인데 지금 비 얼마나 와?"})
    assert out["wants_action"] is False and out["user_info"] is None
    # 키워드 대체: 행동을 묻는 말이 있으면 True, 없으면 None(행동 권고가 재난 단계로 정한다)
    kw = G.make_manager(G.keyword_classify)
    assert kw({"mode": "chat", "user": USER, "question": "침수되면 어떻게 해야 해?"})["wants_action"] is True
    assert kw({"mode": "chat", "user": USER, "question": "비 얼마나 와?"})["wants_action"] is None


def test_openai_classifier_returns_agents_and_requests_structured_output():
    clf = fake_classifier(Classification(
        agents=[Specialist.RAIN_FLOOD, Specialist.LOCATION_ROUTE, Specialist.RAIN_FLOOD], reason="이동 판단"))
    agents = clf({"mode": "chat", "user": USER, "question": "비 오는데 걸어서 가도 돼요?"})

    assert agents == [Specialist.RAIN_FLOOD, Specialist.LOCATION_ROUTE]   # 중복 제거
    call = clf.client.responses.calls[0]
    assert call["model"] == "test-model"
    assert call["text_format"] is Classification
    assert "temperature" not in call            # 추론 모델은 temperature를 받지 않는다
    assert "비 오는데 걸어서 가도 돼요?" in call["input"]


def test_openai_classifier_unparsable_response_raises():
    with pytest.raises(ValueError):
        fake_classifier(None)({"mode": "chat", "user": USER, "question": "?"})


def test_prompt_includes_retry_feedback_and_profile():
    prompt = build_prompt({
        "user": UserProfile(user_id="u1", user_type="tourist", age=72, walking_impaired=True),
        "question": "대피소 어디예요?",
        "manager_feedback": "[intent] 경로를 묻는데 답하지 않음",
    })
    assert "관광객" in prompt and "72세" in prompt and "보행 불편" in prompt
    assert "경로를 묻는데 답하지 않음" in prompt
