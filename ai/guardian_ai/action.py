"""행동 권고 agent와 재난 단계 판정 (B4, docs/agent-design.md 4절).

행동 권고: ① 규칙(코드)이 재난·단계·사용자 유형으로 공식 행동요령 원문(action_guides)을 고른다
→ ② LLM(llm.OpenAIActionWriter)이 그 원문만 바탕으로 사용자 상황에 맞춘 '지금 할 일'을 쓴다 → ③ 환각 검증이 원문과 대조.
LLM이 실패하면 원문(제목: 본문)을 그대로 번호 목록으로 쓴다. 원문에 없는 행동은 만들지 않는다
(유일한 예외: 위험 지역에서 이동이 어려운 사람에게 119 구조 요청 — 판단 트리 D3, 규칙이 넣는다).

재난 단계: 특보·판정 엔진으로 전/중/후/평시를 정한다 (관리자가 부른다).
"""

from __future__ import annotations

import logging
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


def needs_emergency(results: list[SpecialistResult], user: UserProfile | None) -> bool:
    """판단 트리 D2 → D3: 경보 이상 + 이동이 어려움(보행 불편·휠체어) + 안전한 경로가 없음."""
    if user is None or not (user.walking_impaired or user.mobility == Mobility.WHEELCHAIR):
        return False
    if not any(r.risk_level.rank >= RiskLevel.WARNING.rank for r in results):
        return False
    route = next((r.route for r in results if r.agent == Specialist.LOCATION_ROUTE), None)
    return route is None or bool(route.get("still_inside"))


def situation_text(state: GuardianState, results: list[SpecialistResult], main: SpecialistResult | None,
                   phase: Phase, emergency: bool) -> str:
    user = state.get("user")
    lines = []
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
    lines.append(f"- 재난 단계: {phase.value}")
    if main is not None:
        lines.append(f"- 기준 재난: {main.agent.value}, 위험 단계 {LEVEL_KO[main.risk_level.value]}")
    route = next((r for r in results if r.agent == Specialist.LOCATION_ROUTE), None)
    if route is not None and route.route:
        dest = route.route.get("destination") or {}
        lines.append(f"- 위치·경로 안내: {dest.get('name')}까지 {route.route.get('distance_m')}m")
    for m in state.get("user_memory") or []:
        lines.append(f"- 사용자 기억: {m}")
    if emergency:
        lines.append(f"- 119 구조 요청 권고: {EMERGENCY_STEP}")
    return "\n".join(lines)


def guide_lines(guides: list[dict[str, Any]]) -> str:
    return "\n".join(f"- {g['title']}: {g['content']}" for g in guides)


# (질문, 사용자 상황, 원문 목록, 재시도 사유) → 할 일 문장들. 실패하면 예외
ActionWriter = Callable[[str, str, str, str], list[str]]


def make_action_advisor(writer: ActionWriter | None = None, fetch: Fetch | None = None, use_guides: bool = True):
    """행동 권고 노드. use_guides=False면 원문을 찾지 않는다 (오프라인 테스트·기본 그래프 — DB를 부르지 않게)."""
    def action_advisor(state: GuardianState) -> dict:
        results = state.get("specialist_results", [])
        phase = state.get("phase", Phase.NONE)
        parts = [r.summary for r in results if r.summary.strip()]
        if not parts:
            plan = ActionPlan(phase=phase, risk_level=RiskLevel.NORMAL, steps=[])
            return {"action_plan": plan, "draft": NOT_READY if results else NO_RISK}

        user = state.get("user")
        main, guides = pick_guides(results, phase, user, fetch) if use_guides else (primary_result(results), [])
        emergency = needs_emergency(results, user)
        level = main.risk_level if main is not None else RiskLevel.NORMAL
        evidence = [Evidence(source="action_guides", key=f"행동요령: {g['title']}", value=g["content"]) for g in guides]
        if emergency:
            evidence.append(Evidence(source="rule", key="119 구조 요청 권고", value=EMERGENCY_STEP))

        steps: list[str] = []
        how = "-"
        if guides or emergency:
            if writer is not None:
                try:
                    steps = writer(state.get("question") or "", situation_text(state, results, main, phase, emergency),
                                   guide_lines(guides) or "(해당 원문 없음)", state.get("manager_feedback") or "")
                    how = "LLM"
                except Exception as e:  # noqa: BLE001 — LLM 장애로 답이 끊기면 안 된다
                    logger.warning("행동 권고 작성 실패 → 원문 그대로 (%s: %s)", type(e).__name__, e)
            if not steps:
                steps = ([EMERGENCY_STEP] if emergency else []) + [f"{g['title']}: {g['content']}" for g in guides]
                how = "원문"
        logger.info("행동 권고 [%s] 재난=%s 단계=%s/%s 원문=%s 119=%s", how, main.agent.value if main else None,
                    phase.value, level.value, [g["id"] for g in guides], emergency)

        draft = "\n\n".join(parts)
        if steps:
            draft += "\n\n지금 할 일:\n" + "\n".join(f"{n}. {s}" for n, s in enumerate(steps, 1))
        plan = ActionPlan(phase=phase, risk_level=level, steps=steps, guide_ids=[g["id"] for g in guides],
                          call_emergency=emergency, evidence=evidence)
        return {"action_plan": plan, "draft": draft}

    action_advisor.__name__ = "action_advisor"
    return action_advisor


__all__ = ["NOT_READY", "NO_RISK", "decide_phase", "make_action_advisor", "pick_guides", "targets_for",
           "needs_emergency"]
