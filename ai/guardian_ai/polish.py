"""답변 다듬기 (B5): 카드형 필드(코드) + 쉬운 문장·음성용 문장(LLM 한 번) + 다듬은 뒤 숫자 재검증(규칙).

- 카드(`build_card`): 제목(판단 분기 + 가장 높은 위험), 핵심 수치 칩(근거에서 코드가 고름 — LLM이 숫자를 만들지 않게),
  할 일(행동 권고 그대로), 출처, 119 여부. 앱이 카드로 그릴 수 있게 응답에 따로 싣는다.
- 문장(`OpenAIPolisher`): 검증을 통과한 초안을 쉬운 말로, 길면 요약, 음성용 2~3문장. 짧은 초안·평시 정보 답은 생략(지연 절약).
- 재검증(`make_final_check`): 다듬은 글·음성 문장의 숫자가 근거와 맞는지 규칙으로만(`verify.check_numbers`, AI 호출 없음).
  실패 사유는 `polish_feedback`으로 넘겨 한 번 다시 다듬는다(code_check_list #3). 그래도 실패면 다듬기 전 초안.
"""

from __future__ import annotations

import logging
import re
from typing import Any, Callable

from .flood import LEVEL_KO
from .state import Evidence, GuardianState, RiskLevel, Specialist
from .verify import check_numbers

logger = logging.getLogger(__name__)

# 다듬기를 건너뛸 초안 길이 (글자 수). 이보다 짧으면 그대로 쓰고 음성 문장만 코드가 만든다.
# 250이던 것을 600으로 — 다듬기(3~5초) 때문에 재난 중 답이 16초로 목표(15초)를 넘었다 (2026-10-03 live). 요약이 필요한 긴 답만 다듬는다
SKIP_POLISH_CHARS = 600
# 이보다 길면 상황 설명을 요약한다
SUMMARIZE_CHARS = 600
MAX_CHIPS = 5
AGENT_KO = {Specialist.RAIN_FLOOD: "호우·침수", Specialist.WIND_TYPHOON: "강풍·태풍", Specialist.LANDSLIDE: "산사태",
            Specialist.LIFE_SAFETY: "생활안전", Specialist.LOCATION_ROUTE: "대피 경로", Specialist.RECOVERY_SUPPORT: "지원·복구"}
# 위험 단계를 내지 않는 agent — 카드 제목의 '○○ 정상'에서 뺀다
NO_LEVEL_AGENTS = {Specialist.LOCATION_ROUTE, Specialist.RECOVERY_SUPPORT}
# 근거 키 → 칩 (앞에서부터 고른다). (근거 키에 들어 있는 말, 칩 이름)
CHIP_RULES = [("침수 위험 단계", "침수"), ("호우 위험 단계", "호우"), ("산사태 위험 단계", "산사태"), ("태풍 위험 단계", "태풍"),
              ("강풍 위험 단계", "강풍"), ("풍랑 위험 단계", "풍랑"), ("침수심", "침수심"), ("1시간 강수량", "1시간 강수량"),
              ("순간최대풍속", "순간최대풍속"), ("풍속", "풍속"), ("경로 거리", "대피소까지"), ("도보 소요 시간", "도보"),
              ("내일", "내일 예보"), ("자외선 등급", "자외선"), ("미세먼지 등급", "미세먼지"), ("사용자 직업", "내 직업")]
SOURCE_KO = {"risk_assessments": "위험 판정(포항시 판정 엔진)", "observations": "실시간 관측(포항 디지털 트윈·기상청)",
             "forecasts": "기상청 예보", "weather_warnings": "기상청 특보", "disaster_messages": "긴급재난문자",
             "action_guides": "행동요령(포항시 재난안전)", "shelters": "대피소(생활안전지도)", "route": "경로(OpenStreetMap·GraphHopper)",
             "hazard_zones": "산사태 취약지역(공공데이터포털)", "kakao": "장소 검색(카카오)",
             "support_programs": "재난 지원·보험 제도(포항시 재난안전)", "user_profiles": "내 프로필"}


def all_evidence(state: GuardianState) -> list[Evidence]:
    ev = [e for r in state.get("specialist_results", []) for e in r.evidence]
    plan = state.get("action_plan")
    return ev + (plan.evidence if plan is not None else [])


def _chip_value(e: Evidence) -> str:
    v = e.value
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    return f"{v}{e.unit or ''}"


def build_card(state: GuardianState) -> dict[str, Any]:
    """앱용 카드. 모든 값은 근거·판단 결과에서 그대로 (지어내지 않음)."""
    results = state.get("specialist_results", [])
    plan = state.get("action_plan")
    top = max((r for r in results if r.agent not in NO_LEVEL_AGENTS),
              key=lambda r: r.risk_level.rank, default=None)
    path = list(plan.decision_path) if plan is not None else []
    headline_parts = [p for p in path if p not in ("정보 안내",)]
    if top is not None and top.risk_level != RiskLevel.NORMAL:
        headline_parts.append(f"{AGENT_KO[top.agent]} {LEVEL_KO[top.risk_level.value]}")
    elif top is not None:
        headline_parts.append(f"{AGENT_KO[top.agent]} 정상")
    chips: list[dict[str, str]] = []
    used: set[str] = set()
    evidence = all_evidence(state)
    for needle, label in CHIP_RULES:
        if len(chips) >= MAX_CHIPS:
            break
        e = next((x for x in evidence if needle in x.key and x.source != "request"), None)
        if e is None or label in used or e.value in (None, ""):
            continue
        used.add(label)
        chips.append({"label": label, "value": _chip_value(e)})
    sources = list(dict.fromkeys(SOURCE_KO[e.source] for e in evidence if e.source in SOURCE_KO))
    return {"headline": " · ".join(headline_parts), "chips": chips,
            "steps": list(plan.steps) if plan is not None else [], "sources": sources,
            "call_emergency": bool(plan.call_emergency) if plan is not None else False}


def fallback_voice(state: GuardianState, text: str) -> str:
    """LLM 없이 음성용 문장: 119(있으면) + 첫 두 문장 + 첫 할 일 + 질문"""
    plan = state.get("action_plan")
    body = text.split("\n\n지금 할 일:")[0]
    sentences = [s.strip() for s in re.split(r"(?<=[.!?다요])\s+", body.replace("\n", " ")) if s.strip()][:2]
    parts = sentences
    if plan is not None and plan.steps:
        parts = parts + [f"먼저, {plan.steps[0]}"]
    if plan is not None and plan.question:
        parts.append(plan.question)
    return " ".join(parts)


# (초안, 요약 필요, 재다듬기 사유) → (다듬은 글, 음성 문장). 실패하면 예외
Polisher = Callable[[str, bool, str], tuple[str, str]]


def make_polish(polisher: Polisher | None = None):
    def polish(state: GuardianState) -> dict:
        draft = state.get("verified_draft", "")
        card = build_card(state)
        plan = state.get("action_plan")
        info_only = plan is not None and plan.decision_path[-1:] == ["정보 안내"]
        if polisher is None or len(draft) < SKIP_POLISH_CHARS or info_only:
            return {"polished": draft, "voice_text": fallback_voice(state, draft), "card": card}
        try:
            text, voice = polisher(draft, len(draft) > SUMMARIZE_CHARS, state.get("polish_feedback") or "")
            return {"polished": text, "voice_text": voice, "card": card}
        except Exception as e:  # noqa: BLE001 — 다듬기 실패로 답이 끊기면 안 된다
            logger.warning("다듬기 실패 → 초안 그대로 (%s: %s)", type(e).__name__, e)
            return {"polished": draft, "voice_text": fallback_voice(state, draft), "card": card}
    polish.__name__ = "polish"
    return polish


def make_final_check():
    """다듬은 글·음성 문장의 숫자 재검증 (규칙만). 실패 사유는 polish_feedback으로 (#3)."""
    def final_hallucination_check(state: GuardianState) -> dict:
        text = (state.get("polished") or "") + "\n" + (state.get("voice_text") or "")
        result = check_numbers(text, all_evidence(state))
        if result.ok:
            return {"polish_verdict": "pass", "polish_feedback": ""}
        logger.info("다듬기 재검증 실패: %s", result.feedback)
        return {"polish_verdict": "fail", "polish_feedback": result.feedback}
    final_hallucination_check.__name__ = "final_hallucination_check"
    return final_hallucination_check
