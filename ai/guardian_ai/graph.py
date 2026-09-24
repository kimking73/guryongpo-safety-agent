"""agent 그래프 토폴로지.

이 파일은 "어떤 agent가 어떤 순서로 실행되는가"를 정의한다.

전체 흐름
---------
    질문(chat) 또는 경고(alert)
        → manager                관리자: 재난 단계 판정 + 필요한 전문 agent 선택
        → 전문 agent (병렬)        산사태 / 강수·침수 / 강풍·태풍 / 생활안전 / 위치·경로 중 선택된 것만
        → action_advisor          행동 권고: 결과를 모아 행동 우선순위 + 답변 초안
        → intent_check ┐          (병렬) 의도 검증: 질문에 맞게 답했나  ※ alert 모드는 생략
          hallucination_check ┘   (병렬) 환각 검증: 숫자·사실이 근거(DB)와 맞나
        → verify_gate             검증 합류: 통과 / 재시도(관리자로) / 포기(fallback)
        → polish                  답변 다듬기: 표·요약·쉬운 문장
        → final_hallucination_check  다듬다가 내용이 바뀌지 않았나
        → final_check_gate        통과 / 다시 다듬기 / 포기(다듬기 전 초안 사용)
        → finalize                최종 답변 확정

LangGraph 기본 개념
------------------
- 노드(node): 하나의 작업 단위(함수). state를 받아서 "바꿀 필드만" dict로 반환한다.
- state: 모든 노드가 함께 읽고 쓰는 공용 메모장 (state.py의 GuardianState).
- 엣지(edge): "이 노드 다음엔 저 노드" 고정 연결.
- 조건부 엣지(conditional edge): 라우팅 함수가 state를 보고 다음 노드를 고른다.
  리스트를 반환하면 그 노드들이 동시에(병렬) 실행된다.

현재 노드 본문은 stub(가짜 구현)이다. B2~B5에서 LLM 로직으로 교체한다.
연결 구조·재시도 한도는 여기서 확정된 것이므로 바꿀 때는 설계 문서도 함께 고친다.
설계 문서: docs/agent-design.md
"""

from __future__ import annotations

from typing import Callable

from langgraph.graph import END, START, StateGraph
from langgraph.types import Send

from .state import (
    MAX_POLISH_RETRY,   # 다듬기 재시도 한도 (1회)
    MAX_RETRY,          # 검증 실패 시 관리자부터 다시 하는 한도 (2회)
    RESET,              # reducer에 보내면 누적된 값을 비우는 신호
    ActionPlan,
    CheckResult,
    GuardianState,
    Phase,
    RiskLevel,
    Specialist,
    SpecialistResult,
)

# ---------------------------------------------------------------------------
# 노드 이름
# 문자열을 직접 쓰면 오타가 나기 쉬워서 상수로 둔다. 테스트도 이 상수를 쓴다.
# ---------------------------------------------------------------------------

MANAGER = "manager"
ACTION_ADVISOR = "action_advisor"
INTENT_CHECK = "intent_check"
HALLUCINATION_CHECK = "hallucination_check"
VERIFY_GATE = "verify_gate"
POLISH = "polish"
FINAL_HALLUCINATION_CHECK = "final_hallucination_check"
FINAL_CHECK_GATE = "final_check_gate"
FINALIZE = "finalize"
FALLBACK = "fallback"

# 전문 agent 5개의 노드 이름. state.py의 Specialist enum 값과 같다.
# ["landslide_agent", "rain_flood_agent", "wind_typhoon_agent", "life_safety_agent", "location_route_agent"]
SPECIALISTS = [s.value for s in Specialist]

# 노드 함수의 형태: state를 받아 "변경할 필드"만 담은 dict를 반환
Node = Callable[[GuardianState], dict]


# ===========================================================================
# 1. 노드 (각 agent가 하는 일)
#    지금은 전부 stub. 흐름 검증을 위해 최소한의 값만 반환한다.
# ===========================================================================

# [stub 전용] 질문에 들어 있는 단어로 전문 agent를 고른다.
# B2에서 Gemini가 질문을 이해해서 고르는 방식으로 바뀐다.
_KEYWORDS = {
    Specialist.LANDSLIDE: ["산사태", "산", "토사"],
    Specialist.RAIN_FLOOD: ["비", "호우", "침수", "물", "수위"],
    Specialist.WIND_TYPHOON: ["바람", "강풍", "태풍", "파도"],
    Specialist.LIFE_SAFETY: ["미세먼지", "자외선", "공기"],
    Specialist.LOCATION_ROUTE: ["대피", "경로", "길", "가도", "어디"],
}


def manager(state: GuardianState) -> dict:
    """관리자 agent: 재난 단계를 정하고, 호출할 전문 agent를 고른다.

    - chat 모드: 사용자 질문을 보고 고른다.
    - alert 모드: Risk engine이 보낸 경고(risk_event)의 재난 종류를 보고 고른다.
    - 검증 실패로 되돌아온 경우 state["manager_feedback"]에 실패 사유가 있다 (B2에서 활용).
    """
    if state.get("mode") == "alert" and state.get("risk_event"):
        # 경고 모드: 해당 재난 agent + 대피 경로 agent
        disaster = state["risk_event"].disaster.value
        selected = [Specialist.RAIN_FLOOD if disaster in ("flood", "heavy_rain") else Specialist.WIND_TYPHOON,
                    Specialist.LOCATION_ROUTE]
    else:
        # 대화 모드: 질문에 키워드가 있는 agent만 선택 (stub)
        q = state.get("question") or ""
        selected = [s for s, kws in _KEYWORDS.items() if any(k in q for k in kws)]

    return {
        "phase": Phase.DURING,          # stub: 항상 "재난 중". B4에서 특보·위험 판정으로 계산
        "selected_agents": selected,
        # 재시도로 다시 들어온 경우를 대비해 이전 시도의 결과를 비운다.
        # (이걸 안 하면 1차 시도 결과와 2차 시도 결과가 섞여 쌓인다)
        "specialist_results": RESET,
        "checks": RESET,
    }


def _specialist_stub(agent: Specialist) -> Node:
    """전문 agent 5개의 stub을 만드는 공장 함수.

    실제 구현(B3·B4)에서는 각 agent가 tools.py의 조회 함수로 데이터를 가져와
    답변 조각(summary)과 근거(evidence)를 반환한다.
    반환값은 리스트로 감싸야 한다: 병렬로 실행된 여러 agent의 결과가
    state의 merge_results reducer에 의해 하나의 리스트로 합쳐지기 때문이다.
    """
    def node(state: GuardianState) -> dict:
        return {"specialist_results": [SpecialistResult(agent=agent, summary=f"{agent.value} stub")]}
    node.__name__ = agent.value
    return node


def action_advisor(state: GuardianState) -> dict:
    """행동 권고 agent: 전문 agent 결과를 모아 행동 우선순위와 답변 초안을 만든다.

    실제 구현(B4): 판단 트리(재난 전/중/후 → 위험도 → 이동 가능 여부)를 규칙 코드로 돌려
    행동 목록(ActionPlan.steps)을 먼저 확정하고, LLM은 이를 문장으로 풀어 쓰기만 한다.
    → AI가 잘못된 행동요령을 지어내는 것을 막는다.
    """
    results = state.get("specialist_results", [])
    plan = ActionPlan(phase=state.get("phase", Phase.NONE), risk_level=RiskLevel.SAFE, steps=[])
    # stub: 전문 agent 요약을 이어 붙여 초안으로 쓴다. 선택된 agent가 없으면 기본 문구.
    draft = " / ".join(r.summary for r in results) or "현재 확인된 위험 없음"
    return {"action_plan": plan, "draft": draft}


def intent_check(state: GuardianState) -> dict:
    """사용자 의도 검증: 초안이 질문에 제대로 답하는지 확인한다 (B5).

    결과는 checks["intent"]에 기록한다. hallucination_check와 동시에 실행되므로
    서로 다른 키에 써야 merge_checks reducer가 둘을 합칠 수 있다.
    """
    return {"checks": {"intent": CheckResult(ok=True)}}


def hallucination_check(state: GuardianState) -> dict:
    """환각 검증: 초안의 숫자·사실이 전문 agent가 남긴 evidence와 일치하는지 확인한다 (B3).

    예: 초안에 "수위 30cm"가 있는데 evidence에는 22cm뿐이면 ok=False, feedback에 사유 기록.
    """
    return {"checks": {"hallucination": CheckResult(ok=True)}}


def verify_gate(state: GuardianState) -> dict:
    """검증 합류 지점: 병렬로 돌린 검증 결과를 모아 다음 행동을 정한다.

    - 모두 통과          → verdict="pass",     이 초안을 verified_draft로 저장 (루프 2 실패 시 대비)
    - 실패 + 한도 이내(실패 한도)    → verdict="retry",    실패 사유를 관리자에게 전달, retry_count 증가
    - 실패 + 한도 초과    → verdict="fallback", 안전 안내로 종료
    실제 이동은 아래 route_verdict가 verdict 값을 보고 결정한다.
    """
    failed = [f"[{k}] {c.feedback}" for k, c in state.get("checks", {}).items() if not c.ok]
    if not failed:
        return {"verdict": "pass", "verified_draft": state.get("draft", "")}
    retry = state.get("retry_count", 0)
    if retry < MAX_RETRY:
        return {"verdict": "retry", "retry_count": retry + 1, "manager_feedback": "\n".join(failed)}
    return {"verdict": "fallback"}


def polish(state: GuardianState) -> dict:
    """답변 다듬기 agent: 수치는 표로, 긴 글은 요약, 문장은 쉽게 (B5).

    재검증에 실패해 다시 들어온 경우 polish_feedback을 반영해서 다시 다듬는다.
    """
    return {"polished": state.get("verified_draft", "")}


def final_hallucination_check(state: GuardianState) -> dict:
    """환각 재검증: 다듬는 과정에서 숫자·사실이 바뀌지 않았는지 확인한다.

    "pass" 또는 "fail"을 polish_verdict에 기록한다.
    재시도 여부 판단은 바로 다음 노드(final_check_gate)가 한다.
    """
    return {"polish_verdict": "pass"}


def final_check_gate(state: GuardianState) -> dict:
    """환각 재검증 결과로 다시 다듬을지 정한다.

    - 통과          → 그대로 둠 (finalize로)
    - 실패 + 한도 이내 → polish_verdict="retry"   (다시 polish로)
    - 실패 + 한도 초과 → polish_verdict="give_up" (finalize에서 다듬기 전 초안 사용)
    """
    if state.get("polish_verdict") == "pass":
        return {}
    retry = state.get("polish_retry_count", 0)
    if retry < MAX_POLISH_RETRY:
        return {"polish_verdict": "retry", "polish_retry_count": retry + 1}
    return {"polish_verdict": "give_up"}


def finalize(state: GuardianState) -> dict:
    """최종 답변을 확정한다."""
    if state.get("polish_verdict") == "pass":
        return {"final_answer": state.get("polished", ""), "used_fallback": False}
    # 다듬은 답변이 끝내 검증을 못 넘었다 → 모양은 덜 예뻐도
    # 루프 1에서 이미 검증을 통과한 초안을 그대로 내보낸다.
    return {"final_answer": state.get("verified_draft", ""), "used_fallback": False}


def fallback(state: GuardianState) -> dict:
    """루프 1 검증을 한도까지 실패한 경우: 확실한 최소 안내만 한다.

    재난 상황에서 틀린 정보를 주는 것보다 "모른다 + 안전 행동"이 낫다.
    used_fallback=True는 로그·품질 측정(J4)에 쓴다.
    """
    return {
        "final_answer": "정확한 정보를 확인하지 못했습니다. 위급하면 119에 연락하고 가까운 대피소로 이동하세요.",
        "used_fallback": True,
    }


# 노드 이름 → 함수 매핑. build_graph(overrides=...)로 일부만 바꿔 끼울 수 있다.
DEFAULT_NODES: dict[str, Node] = {
    MANAGER: manager,
    **{s.value: _specialist_stub(s) for s in Specialist},   # 전문 agent 5개
    ACTION_ADVISOR: action_advisor,
    INTENT_CHECK: intent_check,
    HALLUCINATION_CHECK: hallucination_check,
    VERIFY_GATE: verify_gate,
    POLISH: polish,
    FINAL_HALLUCINATION_CHECK: final_hallucination_check,
    FINAL_CHECK_GATE: final_check_gate,
    FINALIZE: finalize,
    FALLBACK: fallback,
}


# ===========================================================================
# 2. 라우팅 함수 (갈림길: 다음에 어느 노드로 갈지)
#    state를 읽기만 하고 바꾸지 않는다. 반환값 = 다음 노드 이름(들).
# ===========================================================================

def route_specialists(state: GuardianState) -> list[Send] | str:
    """manager 다음: 선택된 전문 agent들을 병렬로 실행한다.

    Send(노드이름, state)를 여러 개 반환하면 LangGraph가 그 노드들을 동시에 실행한다.
    선택된 agent가 없으면(예: "안녕하세요") 바로 행동 권고로 간다.
    """
    selected = state.get("selected_agents") or []
    if not selected:
        return ACTION_ADVISOR
    return [Send(Specialist(s).value, state) for s in selected]


def route_checks(state: GuardianState) -> list[str]:
    """action_advisor 다음: 어떤 검증을 돌릴지.

    - chat:  의도 검증 + 환각 검증을 동시에
    - alert: 사용자 질문이 없으니 의도 검증은 의미가 없다 → 환각 검증만
    """
    if state.get("mode") == "alert":
        return [HALLUCINATION_CHECK]
    return [INTENT_CHECK, HALLUCINATION_CHECK]


def route_verdict(state: GuardianState) -> str:
    """verify_gate 다음: verdict 값에 따라 이동."""
    return {
        "pass": POLISH,        # 통과 → 다듬기
        "retry": MANAGER,      # 재시도 → 관리자부터 다시 (루프 1)
        "fallback": FALLBACK,  # 한도 초과 → 안전 안내
    }[state["verdict"]]


def route_polish(state: GuardianState) -> str:
    """final_check_gate 다음: "retry"면 다시 다듬기(루프 2), 나머지는 최종 확정."""
    return POLISH if state.get("polish_verdict") == "retry" else FINALIZE


# ===========================================================================
# 3. 그래프 조립
# ===========================================================================

def build_graph(overrides: dict[str, Node] | None = None):
    """노드와 연결을 조립해 실행 가능한 그래프를 만든다.

    overrides: 특정 노드만 다른 함수로 바꿔 끼울 때 사용.
        - 테스트: 검증 실패를 강제하는 가짜 노드 주입
        - 단계별 구현: B3에서 hallucination_check만 실제 구현으로 교체 등
    사용 예:
        app = build_graph()
        result = app.invoke({"mode": "chat", "user": user, "question": "지금 대피해야 하나요?"})
        print(result["final_answer"])
    """
    nodes = {**DEFAULT_NODES, **(overrides or {})}
    g = StateGraph(GuardianState)

    # 노드 등록
    for name, fn in nodes.items():
        g.add_node(name, fn)

    # [1단계] 시작 → 관리자 → 전문 agent(병렬) → 행동 권고
    g.add_edge(START, MANAGER)
    # 세 번째 인자 = 라우팅 함수가 보낼 수 있는 목적지 목록 (그래프 그림을 그릴 때 쓰임)
    g.add_conditional_edges(MANAGER, route_specialists, [*SPECIALISTS, ACTION_ADVISOR])
    for s in SPECIALISTS:
        # 병렬로 실행된 agent들이 모두 끝나면 action_advisor가 "한 번만" 실행된다 (fan-in)
        g.add_edge(s, ACTION_ADVISOR)

    # [2단계] 검증 루프 1: 행동 권고 → 검증(병렬) → 합류 → 통과/재시도/fallback
    g.add_conditional_edges(ACTION_ADVISOR, route_checks, [INTENT_CHECK, HALLUCINATION_CHECK])
    g.add_edge(INTENT_CHECK, VERIFY_GATE)
    g.add_edge(HALLUCINATION_CHECK, VERIFY_GATE)
    g.add_conditional_edges(VERIFY_GATE, route_verdict, [POLISH, MANAGER, FALLBACK])

    # [3단계] 검증 루프 2: 다듬기 → 환각 재검증 → 통과/다시 다듬기/포기
    g.add_edge(POLISH, FINAL_HALLUCINATION_CHECK)
    g.add_edge(FINAL_HALLUCINATION_CHECK, FINAL_CHECK_GATE)
    g.add_conditional_edges(FINAL_CHECK_GATE, route_polish, [POLISH, FINALIZE])

    # [종료] 정상 종료 또는 fallback 종료
    g.add_edge(FINALIZE, END)
    g.add_edge(FALLBACK, END)
    return g.compile()
