"""관리자 agent (B2): alert 라우팅 규칙, 대화 간 초기화, 분류기 장애 대체, Gemini 분류기 호출 형태."""

from datetime import datetime
from types import SimpleNamespace

import pytest

from guardian_ai import graph as G
from guardian_ai.llm import Classification, GeminiClassifier, build_prompt
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
        raise TimeoutError("Gemini 응답 없음")
    out = G.make_manager(broken)({"mode": "chat", "user": USER, "question": "태풍 오면 배는 어떻게 해요?"})
    assert out["selected_agents"] == [Specialist.WIND_TYPHOON]


# --- Gemini 분류기: 실제 호출 없이 요청 형태와 결과 처리만 확인 ---------------------------

class FakeModels:
    def __init__(self, parsed):
        self.parsed, self.calls = parsed, []

    def generate_content(self, **kwargs):
        self.calls.append(kwargs)
        return SimpleNamespace(parsed=self.parsed, text="...")


def fake_classifier(parsed) -> GeminiClassifier:
    return GeminiClassifier(client=SimpleNamespace(models=FakeModels(parsed)), model="test-model")


def test_gemini_classifier_returns_agents_and_requests_structured_output():
    clf = fake_classifier(Classification(
        agents=[Specialist.RAIN_FLOOD, Specialist.LOCATION_ROUTE, Specialist.RAIN_FLOOD], reason="이동 판단"))
    agents = clf({"mode": "chat", "user": USER, "question": "비 오는데 걸어서 가도 돼요?"})

    assert agents == [Specialist.RAIN_FLOOD, Specialist.LOCATION_ROUTE]   # 중복 제거
    call = clf.client.models.calls[0]
    assert call["model"] == "test-model"
    assert call["config"].response_schema is Classification
    assert "비 오는데 걸어서 가도 돼요?" in call["contents"]


def test_gemini_classifier_unparsable_response_raises():
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
