"""stub 노드로 그래프 토폴로지(분기·합류·루프 한도)를 검증한다."""

from datetime import datetime

from guardian_ai import graph as G
from guardian_ai.state import (
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
    # 행동 권고 → 다듬기 → 환각 검증 → 최종 확정 (2026-10-11)
    tail = [n for n in visited if n not in G.SPECIALISTS and n != G.MANAGER]
    assert tail == [G.ACTION_ADVISOR, G.POLISH, G.HALLUCINATION_CHECK, G.VERIFY_GATE, G.FINALIZE]
    assert final["final_answer"] and not final["used_fallback"]


def test_no_specialist_gets_direct_reply_without_advisor_or_checks():
    """인사처럼 전문 agent가 필요 없는 말: 행동 권고·검증을 거치지 않고 서비스 안내만 (위험 여부를 말하지 않는다)."""
    final, visited = run(G.build_graph(), chat("안녕하세요"))
    assert visited == [G.MANAGER, G.DIRECT_REPLY]
    assert final["final_answer"] == G.SERVICE_INTRO and not final["used_fallback"]
    assert "위험" not in final["final_answer"]


def test_alert_without_agents_still_goes_to_advisor():
    """alert 모드는 질문이 없다 — 고를 agent가 없어도 예전처럼 행동 권고로."""
    g = G.build_graph({G.MANAGER: lambda s: {"selected_agents": [], "specialist_results": G.RESET, "checks": G.RESET}})
    final, visited = run(g, {"mode": "alert", "user": USER, "risk_event": RiskEvent(
        disaster=DisasterType.FLOOD, level=RiskLevel.WARNING, location=Location(lat=35.99, lon=129.56),
        issued_at=datetime(2026, 10, 10))})
    assert G.ACTION_ADVISOR in visited and G.DIRECT_REPLY not in visited


def test_failed_check_retries_then_falls_back():
    calls = {"n": 0}

    def always_fail(state):
        calls["n"] += 1
        return {"checks": {"hallucination": CheckResult(ok=False, feedback="수위 수치 불일치")}}

    app = G.build_graph({G.HALLUCINATION_CHECK: always_fail})
    final, visited = run(app, chat("침수 상황 알려줘"))

    assert final["used_fallback"] is True
    # 한도를 넘으면 안전 안내 문장이 아니라 마지막으로 만든 답이 나간다 (사용자 결정 2026-10-11)
    assert final["final_answer"] and final["final_answer"] != G.SAFE_NOTICE
    assert final["retry_count"] == MAX_RETRY
    assert visited.count(G.MANAGER) == MAX_RETRY + 1
    assert "수위 수치 불일치" in final["manager_feedback"]


def test_retry_clears_previous_specialist_results():
    attempts = {"n": 0}

    def fail_once(state):
        attempts["n"] += 1
        return {"checks": {"hallucination": CheckResult(ok=attempts["n"] > 1, feedback="근거와 다름")}}

    final, _ = run(G.build_graph({G.HALLUCINATION_CHECK: fail_once}), chat("침수 상황 알려줘"))
    assert not final["used_fallback"]
    assert len(final["specialist_results"]) == 1  # 재시도 전 결과가 누적되지 않음


def test_bad_polish_is_caught_by_check_then_sent_as_is_after_the_limit():
    """다듬기가 지어낸 값은 그 뒤의 환각 검증(숫자 검사)에서 걸린다 → 한도까지 실패하면 만든 답 그대로 (used_fallback 표시)."""
    def bad_polish(state):
        return {"polished": "수위 99cm (지어낸 값)"}

    final, visited = run(G.build_graph({G.POLISH: bad_polish}), chat("침수 상황 알려줘"))

    assert visited.count(G.POLISH) == MAX_RETRY + 1
    assert final["used_fallback"] is True and final["final_answer"] == "수위 99cm (지어낸 값)"


def test_alert_mode_runs_the_same_checks():
    event = RiskEvent(
        disaster=DisasterType.FLOOD, level=RiskLevel.WARNING,
        location=Location(lat=35.99, lon=129.556), issued_at=datetime(2026, 9, 23, 20, 0),
    )
    final, visited = run(G.build_graph(), {"mode": "alert", "user": USER, "risk_event": event})

    assert G.POLISH in visited and G.HALLUCINATION_CHECK in visited
    assert final["final_answer"]


def test_mermaid_export():
    mermaid = G.build_graph().get_graph().draw_mermaid()
    for name in [G.MANAGER, G.ACTION_ADVISOR, G.VERIFY_GATE, G.FALLBACK, *G.SPECIALISTS]:
        assert name in mermaid


def test_fallback_without_any_answer_uses_safe_notice():
    out = G.fallback({"checks": {}})
    assert out["final_answer"] == G.SAFE_NOTICE and out["voice_text"] == G.SAFE_NOTICE and out["card"] is None
