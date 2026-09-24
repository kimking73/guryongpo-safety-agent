"""stub 노드로 그래프 토폴로지(분기·합류·루프 한도)를 검증한다."""

from datetime import datetime

from guardian_ai import graph as G
from guardian_ai.state import (
    MAX_POLISH_RETRY,
    MAX_RETRY,
    CheckResult,
    DisasterType,
    Location,
    RiskEvent,
    RiskLevel,
    Specialist,
    UserProfile,
)

USER = UserProfile(user_id="u1")


def chat(question: str) -> dict:
    return {"mode": "chat", "user": USER, "question": question}


def run(app, state):
    """한 번 실행하고 (최종 상태, 방문한 노드 순서)를 돌려준다."""
    visited, final = [], None
    for kind, data in app.stream(state, stream_mode=["updates", "values"], config={"recursion_limit": 50}):
        if kind == "updates":
            visited.extend(data.keys())
        else:
            final = data
    return final, visited


def test_chat_runs_only_selected_specialists_and_merges():
    final, visited = run(G.build_graph(), chat("비 오는데 지금 걸어서 집에 가도 되나요?"))

    ran = {n for n in visited if n in G.SPECIALISTS}
    assert ran == {Specialist.RAIN_FLOOD.value, Specialist.LOCATION_ROUTE.value}
    assert visited.count(G.ACTION_ADVISOR) == 1  # fan-in은 한 번만
    assert {r.agent for r in final["specialist_results"]} == {Specialist.RAIN_FLOOD, Specialist.LOCATION_ROUTE}
    assert G.INTENT_CHECK in visited and G.HALLUCINATION_CHECK in visited
    assert final["final_answer"] and not final["used_fallback"]


def test_no_specialist_goes_straight_to_advisor():
    final, visited = run(G.build_graph(), chat("안녕하세요"))
    assert not any(n in G.SPECIALISTS for n in visited)
    assert final["final_answer"] == "현재 확인된 위험 없음"


def test_failed_check_retries_then_falls_back():
    calls = {"n": 0}

    def always_fail(state):
        calls["n"] += 1
        return {"checks": {"hallucination": CheckResult(ok=False, feedback="수위 수치 불일치")}}

    app = G.build_graph({G.HALLUCINATION_CHECK: always_fail})
    final, visited = run(app, chat("침수 상황 알려줘"))

    assert final["used_fallback"] is True
    assert final["retry_count"] == MAX_RETRY
    assert visited.count(G.MANAGER) == MAX_RETRY + 1
    assert "수위 수치 불일치" in final["manager_feedback"]


def test_retry_clears_previous_specialist_results():
    attempts = {"n": 0}

    def fail_once(state):
        attempts["n"] += 1
        return {"checks": {"intent": CheckResult(ok=attempts["n"] > 1, feedback="질문과 무관")}}

    final, _ = run(G.build_graph({G.INTENT_CHECK: fail_once}), chat("침수 상황 알려줘"))
    assert not final["used_fallback"]
    assert len(final["specialist_results"]) == 1  # 재시도 전 결과가 누적되지 않음


def test_polish_loop_limited_and_keeps_verified_draft():
    def bad_polish(state):
        return {"polished": "수위 99cm (지어낸 값)"}

    def final_fail(state):
        return {"polish_verdict": "fail"}

    app = G.build_graph({G.POLISH: bad_polish, G.FINAL_HALLUCINATION_CHECK: final_fail})
    final, visited = run(app, chat("침수 상황 알려줘"))

    assert visited.count(G.POLISH) == MAX_POLISH_RETRY + 1
    assert final["final_answer"] == final["verified_draft"]
    assert "99cm" not in final["final_answer"]


def test_alert_mode_skips_intent_check():
    event = RiskEvent(
        disaster=DisasterType.FLOOD, level=RiskLevel.WARNING,
        location=Location(lat=35.99, lon=129.556), issued_at=datetime(2026, 9, 23, 20, 0),
    )
    final, visited = run(G.build_graph(), {"mode": "alert", "user": USER, "risk_event": event})

    assert G.INTENT_CHECK not in visited
    assert G.HALLUCINATION_CHECK in visited
    assert final["final_answer"]


def test_mermaid_export():
    mermaid = G.build_graph().get_graph().draw_mermaid()
    for name in [G.MANAGER, G.ACTION_ADVISOR, G.VERIFY_GATE, G.FALLBACK, *G.SPECIALISTS]:
        assert name in mermaid
