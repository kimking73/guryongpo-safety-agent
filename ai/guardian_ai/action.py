"""행동 권고 agent와 재난 단계 판정 (B4, docs/agent-design.md 4절).

행동 권고: ① 규칙(코드)이 재난·단계·사용자 유형으로 공식 행동요령 원문(action_guides)을 고른다
→ ② LLM(llm.OpenAIActionWriter)이 그 원문만 바탕으로 사용자 상황에 맞춘 '지금 할 일'을 쓴다 → ③ 환각 검증이 원문과 대조.
LLM이 실패하면 원문(제목: 본문)을 그대로 번호 목록으로 쓴다. 원문에 없는 행동은 만들지 않는다
(유일한 예외: 위험 지역에서 이동이 어려운 사람에게 119 구조 요청 — 판단 트리 D3, 규칙이 넣는다).

재난 단계: 특보·판정 엔진으로 전/중/후/평시를 정한다 (관리자가 부른다).
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any, Callable

from . import tools as T
from .db import Fetch
from .flood import LEVEL_KO, pick_location
from .state import (ActionPlan, Evidence, GuardianState, Mobility, Phase, RiskLevel, Specialist, SpecialistResult,
                    UserProfile)

logger = logging.getLogger(__name__)

# 아직 구현 전인 agent만 고른 질문의 답 (지금은 쓰일 일이 거의 없다 — 남은 stub이 없으면)
NOT_READY = "이 질문은 아직 답변을 준비 중입니다. 지금은 침수·호우 상황과 대피소·경로를 안내할 수 있습니다."
NO_RISK = "현재 확인된 위험 없음"

# 전문 agent → 행동요령을 찾을 재난 (action_guides.hazard)
GUIDE_HAZARDS: dict[Specialist, tuple[str, ...]] = {
    Specialist.RAIN_FLOOD: ("flood", "heavy_rain"),
    Specialist.WIND_TYPHOON: ("typhoon", "strong_wind", "high_seas"),
    Specialist.LANDSLIDE: ("landslide",),
    Specialist.LIFE_SAFETY: ("uv", "fine_dust", "ultrafine_dust"),
}
# 단계가 같으면 이 순서로 고른다 (구룡포에서 피해가 큰 순)
TIE_ORDER = [Specialist.RAIN_FLOOD, Specialist.WIND_TYPHOON, Specialist.LANDSLIDE, Specialist.LIFE_SAFETY]
MAX_GUIDES = 3
# 재난 단계: 특보 해제 후 이 시간 안이면 '재난 후' (agent-design.md 7절 열린 질문 → 2026-10-03 24시간으로 정함)
LIFTED_HOURS = 24
# 재난 단계에 쓰지 않는 판정 (생활안전은 '재난 중'으로 보지 않는다)
NON_DISASTER = {"uv", "fine_dust", "ultrafine_dust"}
FISHER_WORDS = ("어업", "어선", "선박", "선장", "어부", "양식", "수산")
EMERGENCY_STEP = "위험 지역에서 이동이 어려우면 119에 구조를 요청하세요."


# --- 재난 단계 -------------------------------------------------------------------

def decide_phase(state: GuardianState, fetch: Fetch | None = None) -> Phase:
    """중: 특보 발효 또는 기준 위치 반경 500m에 주의 이상 판정 / 전: 예비특보만 / 후: 해제 24시간 안 / 그 밖 평시.
    DB에 닿지 않으면 '중'(안전 쪽)."""
    location, _ = pick_location(state)
    warnings = T.get_weather_warnings(lifted_hours=LIFTED_HOURS, fetch=fetch)
    risk = T.get_risk_at(location.lat, location.lon, radius_m=500, fetch=fetch)
    if not warnings.get("available") and not risk.get("available"):
        return Phase.DURING
    statuses = {w["status"] for w in warnings.get("items", []) if w["hazard"] not in NON_DISASTER}
    risky = any(RiskLevel(i["level"]).rank >= RiskLevel.ADVISORY.rank for i in risk.get("items", [])
                if i["hazard"] not in NON_DISASTER)
    if "active" in statuses or risky:
        return Phase.DURING
    if "planned" in statuses:
        return Phase.BEFORE
    if "lifted" in statuses:
        return Phase.AFTER
    return Phase.NONE


# --- 행동요령 고르기 (규칙) ---------------------------------------------------------

def targets_for(user: UserProfile | None) -> list[str]:
    """action_guides.targets 값. all은 tools.get_action_guides가 항상 넣는다."""
    if user is None:
        return ["resident"]
    out = ["resident" if user.user_type == "resident" else "tourist"]
    if any(w in (user.occupation or "") for w in FISHER_WORDS):
        out += ["fisher", "vessel_owner", "coastal"]
    if user.mobility == Mobility.CAR:
        out.append("driver")
    return out


def primary_result(results: list[SpecialistResult]) -> SpecialistResult | None:
    """행동요령을 고를 기준 재난: 단계가 가장 높은 전문 agent (위치·경로 제외, 같으면 TIE_ORDER)."""
    candidates = [r for r in results if r.agent in GUIDE_HAZARDS and r.summary.strip()]
    if not candidates:
        return None
    return max(candidates, key=lambda r: (r.risk_level.rank, -TIE_ORDER.index(r.agent)))


def pick_guides(results: list[SpecialistResult], phase: Phase, user: UserProfile | None,
                fetch: Fetch | None = None) -> tuple[SpecialistResult | None, list[dict[str, Any]]]:
    """(기준 재난 결과, 원문 최대 MAX_GUIDES건). 평시면 '재난 전' 원문 → 없으면 '관심' 단계 '재난 중' 원문."""
    main = primary_result(results)
    if main is None:
        return None, []
    level = max(main.risk_level, RiskLevel.WATCH, key=lambda lv: lv.rank)
    phases = [Phase.BEFORE, Phase.DURING] if phase in (Phase.NONE, Phase.BEFORE) else [phase]
    targets = targets_for(user)
    for ph in phases:
        found: dict[str, dict[str, Any]] = {}
        for hazard in GUIDE_HAZARDS[main.agent]:
            res = T.get_action_guides(hazard, ph.value, level.value, targets, fetch=fetch)
            for g in res.get("items", []):
                found.setdefault(g["title"], g)          # 같은 제목(여러 재난에 같은 원문)은 한 번만
        if found:
            # 직업 대상(어업인·운전자 등) 원문을 앞에, 그다음 원문 우선순위. 관광객·주민 대상 원문은 장소별(해수욕장 등)이라
            # 앞에 두지 않는다 — 지금 그 장소에 있는지 몰라 검증에서 걸렸다 (2026-10-03 실측)
            jobs = set(targets) - {"resident", "tourist"}
            ranked = sorted(found.values(), key=lambda g: (not jobs & set(g.get("targets") or []), g["priority"]))
            return main, ranked[:MAX_GUIDES]
    return main, []


# --- 판단 로직 (사용자 정의 트리, 2026-10-03) --------------------------------------------
# 재난 전: 대비 행동요령 + 예보 → 필요한 사용자 정보(동반자) 조사 → 체크리스트
# 재난 중: 행동요령 → 위험 정도(위치 × 위험 영역) → 안전: 행동요령·실시간 정보 / 위험 지역: 이동 가능?
#          → 불가: 119 구조 요청(맨 앞) / 가능: 대피소 경로
# 재난 후: 행동요령 → 피해 유무(대화) → 없음: 실시간 현황 / 있음: 실시간 현황·임시 거주지·주의사항·보험·법률
# 판정할 근거가 없으면 그 분기에서 멈추고 질문 하나 (안내는 함께 준다 — 사용자 결정). 위험 지역 판정 불가 → 위험 지역.

# 평시에 행동 권고를 붙일 질문 (대비·행동을 묻는 말). 재난 전·중·후에는 항상 붙인다
ACTION_WORDS = ("어떻게", "뭘 해", "무엇을 해", "해야", "대비", "준비", "대피", "피해야", "조심", "주의", "할 일", "행동")

QUESTIONS = {
    "dependents": "함께 대피해야 할 어린이·어르신이나 거동이 불편한 가족이 있나요?",
    "can_move": "지금 스스로 안전한 곳까지 이동하실 수 있나요?",
    "damage": "집이나 건물에 침수·파손 같은 피해가 있나요?",
}
NOT_CONFIRMED = "확인되지 않음"


@dataclass
class Decision:
    path: list[str]
    guide_phase: Phase
    question: str | None = None
    emergency: bool = False
    need_route: bool = False
    notes: list[Evidence] = field(default_factory=list)   # 규칙이 정한 사실 (분기 판정 근거, '확인되지 않음' 항목)


def _hard_to_move(user: UserProfile | None) -> bool:
    """프로필만 보면 스스로 이동이 어려울 수 있는 사람 (대화로 확인해야 함)"""
    return user is not None and bool(user.walking_impaired or user.mobility == Mobility.WHEELCHAIR
                                     or (user.age is not None and user.age >= 75) or user.has_dependents)


def decide(state: GuardianState, fetch: Fetch | None = None, use_data: bool = True) -> Decision:
    """판단 로직을 위에서 아래로 따라간다. use_data=False면 위험 지역 조회를 하지 않는다(DB 없는 테스트·기본 그래프)."""
    phase = state.get("phase", Phase.NONE)
    user = state.get("user")

    if phase in (Phase.BEFORE, Phase.NONE):
        d = Decision(path=["재난 전" if phase == Phase.BEFORE else "평시(대비)"], guide_phase=Phase.BEFORE)
        if user is None or user.has_dependents is None:
            d.path.append("사용자 정보 확인")
            d.question = QUESTIONS["dependents"]
        else:
            d.path.append("체크리스트")
        return d

    if phase == Phase.AFTER:
        d = Decision(path=["재난 후"], guide_phase=Phase.AFTER,
                     notes=[Evidence(source="rule", key="통제 도로", value=NOT_CONFIRMED)])
        damage = state.get("damage", "unknown")
        if damage == "unknown":
            d.path.append("피해 확인")
            d.question = QUESTIONS["damage"]
        elif damage == "no":
            d.path.append("피해 없음")
        else:
            d.path.append("피해 존재")
            d.notes += [Evidence(source="rule", key="보험·법률 정보", value=NOT_CONFIRMED)]
        return d

    # 재난 중
    d = Decision(path=["재난 중"], guide_phase=Phase.DURING)
    location, known = pick_location(state)
    if use_data:
        hz = T.hazards_at(location.lat, location.lon, fetch=fetch)
        in_danger = (not hz.get("available")) or bool(hz.get("labels"))   # 판정 불가 → 위험 지역 (규칙)
        if hz.get("available") and hz.get("labels"):
            d.notes.append(Evidence(source="risk_assessments", key="사용자 위치", value=f"위험 영역 안({hz['labels']})"))
        elif hz.get("available"):
            d.notes.append(Evidence(source="risk_assessments", key="사용자 위치", value="침수·산사태 위험 영역 밖"))
        else:
            d.notes.append(Evidence(source="rule", key="사용자 위치", value="위험 영역 여부 확인되지 않음 → 위험 지역으로 안내"))
    else:
        in_danger = True
    if not known:
        in_danger = True                                                    # 위치를 모름 → 위험 지역으로
    if not in_danger:
        d.path.append("안전")
        return d
    d.path.append("위험 지역")
    can_move = state.get("can_move", "unknown")
    if can_move == "unknown" and not _hard_to_move(user):
        can_move = "yes"                                                    # 프로필상 이동에 어려움 없음
    if can_move == "no":
        d.path.append("이동 불가능")
        d.emergency = True
        d.notes.append(Evidence(source="rule", key="119 구조 요청 권고", value=EMERGENCY_STEP))
        # "무리하게 이동하지 마세요"를 검증기가 원문에 없는 새 지시로 막았다 (2026-10-03 live) → 판단 결과를 근거로
        d.notes.append(Evidence(source="rule", key="판단 결과",
                                value="스스로 이동할 수 없음 → 무리하게 이동하지 말고 안전한 곳에서 구조를 기다림"))
    elif can_move == "yes":
        d.path.append("이동 가능")
        d.need_route = True
    else:
        d.path.append("이동 가능 여부 확인")
        d.question = QUESTIONS["can_move"]
        d.need_route = True                                                 # 안내 + 질문: 갈 수 있다면 쓸 경로를 함께
    return d


def _route_evidence(state: GuardianState, results: list[SpecialistResult], fetch: Fetch | None):
    """대피소 경로: 위치·경로 agent가 이미 냈으면 그것, 아니면 여기서 가장 가까운 안전한 대피소로 계산."""
    done = next((r for r in results if r.agent == Specialist.LOCATION_ROUTE and r.route), None)
    if done is not None:
        return done.route, []
    from . import location as L
    data = L.collect({**state, "destination_query": None}, fetch=fetch)
    return L.route_info(data), [e for e in data.evidence if e.key != "기준 위치"]


def situation_text(state: GuardianState, decision: Decision, main: SpecialistResult | None,
                   route: dict[str, Any] | None) -> str:
    user = state.get("user")
    lines = [f"- 도달한 분기: {' > '.join(decision.path)}"]
    if user is not None:
        who = ["주민" if user.user_type == "resident" else "관광객"]
        if user.age:
            who.append(f"{user.age}세")
        if user.walking_impaired:
            who.append("보행 불편")
        if user.mobility:
            who.append(f"이동수단 {user.mobility.value}")
        if user.occupation:
            who.append(f"직업 {user.occupation}")
        lines.append("- 사용자: " + ", ".join(who))
    if main is not None:
        lines.append(f"- 기준 재난: {main.agent.value}, 위험 단계 {LEVEL_KO[main.risk_level.value]}")
    for n in decision.notes:
        lines.append(f"- {n.key}: {n.value}")
    if route:
        dest = route.get("destination") or {}
        lines.append(f"- 대피소 경로: {dest.get('name')}까지 {route.get('distance_m')}m, 도보 약 {-(-route.get('duration_s', 0) // 60)}분")
    for m in state.get("user_memory") or []:
        lines.append(f"- 사용자 기억: {m}")
    return "\n".join(lines)


def guide_lines(guides: list[dict[str, Any]]) -> str:
    return "\n".join(f"- {g['title']}: {g['content']}" for g in guides)


def template_steps(decision: Decision, guides: list[dict[str, Any]], route: dict[str, Any] | None) -> list[str]:
    """LLM 없이: 119(이동 불가) → 대피소 경로 → 원문 그대로 → 확인되지 않은 항목"""
    steps = [EMERGENCY_STEP] if decision.emergency else []
    if route:
        dest = route.get("destination") or {}
        steps.append(f"{dest.get('name')}(으)로 대피하세요. {route.get('distance_m')}m, 도보 약 {-(-route.get('duration_s', 0) // 60)}분입니다.")
    steps += [f"{g['title']}: {g['content']}" for g in guides]
    steps += [f"{n.key}: {n.value}" for n in decision.notes if n.value == NOT_CONFIRMED]
    return steps


# (질문, 사용자 상황·분기, 원문 목록, 재시도 사유) → 할 일 문장들. 실패하면 예외
ActionWriter = Callable[[str, str, str, str], list[str]]


def make_action_advisor(writer: ActionWriter | None = None, fetch: Fetch | None = None, use_guides: bool = True):
    """행동 권고 노드 (판단 로직 → 원문·경로 → 작성). use_guides=False면 DB를 부르지 않는다 (오프라인 테스트·기본 그래프)."""
    def action_advisor(state: GuardianState) -> dict:
        results = state.get("specialist_results", [])
        phase = state.get("phase", Phase.NONE)
        parts = [r.summary for r in results if r.summary.strip()]
        if not parts:
            plan = ActionPlan(phase=phase, risk_level=RiskLevel.NORMAL, steps=[])
            return {"action_plan": plan, "draft": NOT_READY if results else NO_RISK}

        user = state.get("user")
        if phase == Phase.NONE and not any(w in (state.get("question") or "") for w in ACTION_WORDS):
            # 평시에 정보만 묻는 질문("내일 비 와?")에는 행동 권고·질문을 붙이지 않는다
            plan = ActionPlan(phase=phase, risk_level=RiskLevel.NORMAL, steps=[], decision_path=["평시", "정보 안내"])
            return {"action_plan": plan, "draft": "\n\n".join(parts)}
        decision = decide(state, fetch=fetch, use_data=use_guides)
        main, guides = (pick_guides(results, decision.guide_phase, user, fetch) if use_guides
                        else (primary_result(results), []))
        route, route_ev = (None, [])
        if decision.need_route and use_guides:
            route, route_ev = _route_evidence(state, results, fetch)
        forecast_ev: list[Evidence] = []
        if use_guides and decision.guide_phase == Phase.BEFORE and not any(
                e.source == "forecasts" for r in results for e in r.evidence):
            loc, _ = pick_location(state)
            from .flood import forecast_evidence
            forecast_ev = forecast_evidence(T.get_forecast(loc.lat, loc.lon, hours=48, fetch=fetch))
            if not forecast_ev:
                decision.notes.append(Evidence(source="rule", key="예보", value=NOT_CONFIRMED))
        level = main.risk_level if main is not None else RiskLevel.NORMAL
        evidence = ([Evidence(source="action_guides", key=f"행동요령: {g['title']}", value=g["content"]) for g in guides]
                    + decision.notes + route_ev + forecast_ev)

        steps: list[str] = []
        how = "-"
        if guides or decision.emergency or route or decision.notes:
            if writer is not None:
                try:
                    steps = writer(state.get("question") or "", situation_text(state, decision, main, route),
                                   guide_lines(guides) or "(해당 원문 없음)", state.get("manager_feedback") or "")
                    if decision.emergency and (not steps or "119" not in steps[0]):
                        steps = [EMERGENCY_STEP, *steps]               # 이동 불가 → 구조 요청이 맨 앞 (규칙)
                    how = "LLM"
                except Exception as e:  # noqa: BLE001 — LLM 장애로 답이 끊기면 안 된다
                    logger.warning("행동 권고 작성 실패 → 원문 그대로 (%s: %s)", type(e).__name__, e)
                    steps = []
            if not steps:
                steps, how = template_steps(decision, guides, route), "원문"
        path = " > ".join(decision.path)
        logger.info("행동 권고 [%s] 분기=%s 재난=%s 원문=%s 경로=%s 질문=%s", how, path,
                    main.agent.value if main else None, [g["id"] for g in guides], bool(route), bool(decision.question))

        draft = "\n\n".join(parts)
        # 위험 지역 판단은 코드가 맨 앞에 밝힌다. 전문 agent는 이 판단을 모른 채 "위험 단계 정상"만 쓸 수 있어
        # 검증기가 "위험을 낮춰 말함"으로 막았다 (2026-10-03 live)
        if "위험 지역" in decision.path:
            where = next((n.value for n in decision.notes if n.key == "사용자 위치"), "")
            reason = (f"현재 위치가 {where}에 있어" if where.startswith("위험 영역 안")
                      else "현재 위치의 위험 여부를 확인할 수 없어" if where else "현재 위치를 알 수 없어")
            draft = f"{reason} 위험 지역 기준으로 안내합니다.\n\n" + draft
        if decision.emergency:
            draft = EMERGENCY_STEP + "\n\n" + draft                      # 답변 맨 앞에도 (판단 로직 규칙)
        if steps:
            draft += "\n\n지금 할 일:\n" + "\n".join(f"{n}. {s}" for n, s in enumerate(steps, 1))
        missing = [n.key for n in decision.notes if n.value == NOT_CONFIRMED]
        if missing:                                                     # 값이 없으면 '확인되지 않음' (판단 로직 규칙, AI에 맡기지 않음)
            draft += "\n\n확인되지 않음: " + ", ".join(missing)
        if decision.question:
            draft += f"\n\n확인할게요: {decision.question}"
        plan = ActionPlan(phase=phase, risk_level=level, steps=steps, guide_ids=[g["id"] for g in guides],
                          call_emergency=decision.emergency, evidence=evidence, decision_path=decision.path,
                          question=decision.question, route=route)
        return {"action_plan": plan, "draft": draft}

    action_advisor.__name__ = "action_advisor"
    return action_advisor


__all__ = ["NOT_READY", "NO_RISK", "QUESTIONS", "Decision", "decide", "decide_phase", "make_action_advisor",
           "pick_guides", "targets_for"]
