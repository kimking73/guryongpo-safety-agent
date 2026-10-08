"""지원·복구 안내 agent (2026-10-08) — 사용자가 보험·피해 신고·복구 지원을 물으면 세 구역으로 안내한다.

1. 공통 보험            support_programs.category = insurance, 대상이 모두·주민
2. 공통 피해 신고·복구   category = recovery·livelihood·legal·medical, 대상이 모두·주민
3. 내 직업 지원·복구     대상(targets)이 사용자 직업과 겹치는 제도 (공통에 이미 든 것 제외)

직업은 서버 프로필(user_profiles.occupation → tools.get_user_profile이 한글 이름으로)에서 온다.
DB(support_programs)에 있는 제도만 근거로 넣는다 — 없는 제도·금액은 말하지 않고 "DB에 등록된 제도 없음"을 밝힌다
(사용자 결정 2026-10-08: 지금 있는 데이터만으로). 문장은 OpenAISpecialistWriter, 실패하면 recovery_template.
"""

from __future__ import annotations

from typing import Any

from . import tools as T
from .db import Fetch
from .specialists import Collected, Writer, _start, make_specialist
from .state import Evidence, GuardianState, Specialist

SECTIONS = ("공통 보험", "공통 피해 신고·복구", "내 직업 지원·복구")
COMMON_INSURANCE = {"insurance"}
COMMON_RECOVERY = {"recovery", "livelihood", "legal", "medical"}
# 직업(한글 이름·서버 코드) → support_programs.targets
JOB_TARGETS = [
    ("fisher", ("어업", "뱃사람", "선원", "어선", "선장", "어부", "수산", "양식", "해녀", "fisher", "aquaculture")),
    ("farmer", ("농업", "농사", "농부", "축산", "가축", "과수", "farmer", "livestock")),
]
TARGET_KO = {"fisher": "어업·양식업", "farmer": "농업·축산업"}
# 질문에 나온 재난 → support_programs.hazards (있으면 그 재난 제도만)
HAZARD_WORDS = [
    ("typhoon", ("태풍",)), ("landslide", ("산사태", "토사")), ("high_seas", ("풍랑", "파도", "너울")),
    ("strong_wind", ("강풍", "바람")), ("flood", ("침수",)), ("heavy_rain", ("호우", "폭우", "비 ", "비가", "비로")),
]
HAZARD_KO = {"typhoon": "태풍", "landslide": "산사태", "high_seas": "풍랑", "strong_wind": "강풍", "flood": "침수",
             "heavy_rain": "호우"}
NO_PROGRAM = "DB에 등록된 제도 없음 — 읍면동 행정복지센터에 문의"


def job_targets(occupation: str | None) -> set[str]:
    o = (occupation or "").strip()
    return {t for t, words in JOB_TARGETS if any(w in o for w in words)}


def hazard_of(question: str | None) -> str | None:
    q = f"{question or ''} "
    return next((h for h, words in HAZARD_WORDS if any(w in q for w in words)), None)


def _program_text(p: dict[str, Any]) -> str:
    parts = [p.get("summary") or ""]
    for key, label in (("eligibility", "대상"), ("how_to_apply", "신청"), ("apply_period", "기간"),
                       ("department", "담당"), ("contact", "문의"), ("url", "안내")):
        if p.get(key):
            parts.append(f"{label}: {p[key]}")
    return " / ".join(x for x in parts if x)


def split_sections(programs: list[dict[str, Any]], user_targets: set[str], jobs: set[str]) -> dict[str, list[dict]]:
    """제도 목록 → 세 구역 (한 제도는 한 구역에만)"""
    out: dict[str, list[dict]] = {s: [] for s in SECTIONS}
    for p in programs:
        targets = set(p.get("targets") or [])
        if targets & user_targets and p.get("category") in COMMON_INSURANCE:
            out["공통 보험"].append(p)
        elif targets & user_targets and p.get("category") in COMMON_RECOVERY:
            out["공통 피해 신고·복구"].append(p)
        elif targets & jobs:
            out["내 직업 지원·복구"].append(p)
    return out


def collect_recovery(state: GuardianState, fetch: Fetch | None = None) -> Collected:
    d = _start(state)
    user = state.get("user")
    occupation = (getattr(user, "occupation", None) or "").strip()
    jobs = job_targets(occupation)
    user_targets = {"all"} | ({"resident"} if getattr(user, "user_type", "resident") != "tourist" else set())
    hazard = hazard_of(state.get("question"))
    d.facts.update(occupation=occupation, jobs=jobs, hazard=hazard)
    d.evidence.append(Evidence(source="user_profiles", key="사용자 직업", value=occupation or "미입력 (프로필에서 직업을 입력하면 직업별 지원도 안내)"))
    if hazard:
        d.evidence.append(Evidence(source="question", key="질문한 재난", value=HAZARD_KO[hazard]))

    res = T.get_support_programs(hazard=hazard, fetch=fetch)
    if not res.get("available"):
        d.unavailable.append("지원·복구 제도 목록")
        d.facts["sections"] = {}
        return d
    sections = split_sections(res["items"], user_targets, jobs)
    d.facts["sections"] = sections
    for name in SECTIONS:
        for p in sections[name]:
            d.evidence.append(Evidence(source="support_programs", key=f"[{name}] {p['name']}", value=_program_text(p)))
    if not sections["내 직업 지원·복구"]:
        what = (", ".join(TARGET_KO[j] for j in sorted(jobs)) or occupation) if occupation else "직업 미입력"
        d.evidence.append(Evidence(source="support_programs", key="[내 직업 지원·복구]", value=f"{what}: {NO_PROGRAM}"))
    return d


def recovery_template(d: Collected) -> str:
    sections: dict[str, list[dict]] = d.facts.get("sections") or {}
    if not sections:
        return "지원·복구 제도 목록을 지금 확인할 수 없습니다. 읍면동 행정복지센터에 문의해 주세요."
    lines = []
    if d.facts.get("hazard"):
        lines.append(f"{HAZARD_KO[d.facts['hazard']]} 피해 기준 지원·복구 제도입니다.")
    for name in SECTIONS:
        items = sections.get(name) or []
        body = "; ".join(f"{p['name']} — {p.get('summary', '')}" for p in items) or NO_PROGRAM
        lines.append(f"[{name}] {body}")
    if not d.facts.get("occupation"):
        lines.append("프로필에 직업을 입력하시면 직업에 맞는 지원도 안내해 드립니다.")
    lines.append("지급 여부와 금액은 담당 기관 확인 후 정해집니다.")
    return "\n".join(lines)


def make_recovery_support_agent(writer: Writer | None = None, fetch: Fetch | None = None):
    return make_specialist(Specialist.RECOVERY_SUPPORT, collect_recovery, recovery_template, writer, fetch)


__all__ = ["make_recovery_support_agent", "collect_recovery", "recovery_template", "job_targets", "hazard_of",
           "split_sections"]
