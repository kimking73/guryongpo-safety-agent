"""LangGraph 상태 스키마와 도메인 모델.

설계 문서: docs/agent-design.md
"""

from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import Annotated, Any, Literal, TypedDict

from pydantic import BaseModel, Field


# ---------------------------------------------------------------------------
# Enum
# ---------------------------------------------------------------------------

class DisasterType(str, Enum):
    LANDSLIDE = "landslide"      # 산사태
    HEAVY_RAIN = "heavy_rain"    # 호우
    FLOOD = "flood"              # 침수
    STRONG_WIND = "strong_wind"  # 강풍
    TYPHOON = "typhoon"          # 태풍
    FINE_DUST = "fine_dust"      # 미세먼지 (생활안전)
    UV = "uv"                    # 자외선 (생활안전)


class Phase(str, Enum):
    """행동 권고 판단 트리의 첫 분기."""
    BEFORE = "before"  # 재난 전: 예보·주의보 예정
    DURING = "during"  # 재난 중: 특보 발효 또는 위험 판정
    AFTER = "after"    # 재난 후: 특보 해제 후 일정 시간
    NONE = "none"      # 평시


class RiskLevel(str, Enum):
    SAFE = "safe"
    ADVISORY = "advisory"  # 주의보·주의
    WARNING = "warning"    # 경보·위험


class Specialist(str, Enum):
    """전문 agent 이름. graph.py 노드 이름과 같다."""
    LANDSLIDE = "landslide_agent"
    RAIN_FLOOD = "rain_flood_agent"
    WIND_TYPHOON = "wind_typhoon_agent"
    LIFE_SAFETY = "life_safety_agent"
    LOCATION_ROUTE = "location_route_agent"


class Mobility(str, Enum):
    WALK = "walk"
    CAR = "car"
    WHEELCHAIR = "wheelchair"
    PUBLIC = "public_transport"


# ---------------------------------------------------------------------------
# 도메인 모델
# ---------------------------------------------------------------------------

class Location(BaseModel):
    lat: float
    lon: float
    label: str | None = None  # "집", "직장" 등


class UserProfile(BaseModel):
    """선제 경고와 맞춤 답변에 쓰는 사용자 정보.

    기본 정보(home, age, mobility)는 가입 시 수집, 나머지는 대화 중 필요할 때 수집.
    """
    user_id: str
    user_type: Literal["resident", "tourist"] = "resident"
    # 기본
    home: Location | None = None
    age: int | None = None
    mobility: Mobility | None = None
    # 부가
    frequent_places: list[Location] = Field(default_factory=list)
    has_dependents: bool | None = None       # 보호가 필요한 동반자
    walking_impaired: bool | None = None
    visual_impaired: bool | None = None
    hearing_impaired: bool | None = None
    blood_type: str | None = None
    occupation: str | None = None            # 예: "어업(선박 보유)"
    emergency_contact: str | None = None


class Evidence(BaseModel):
    """답변에 쓴 수치·사실의 근거. 환각 검증이 이 목록과 초안을 대조한다."""
    source: str             # 예: "pohang_twin.water_level", "kma.warning"
    key: str                # 예: "구룡포항 수위"
    value: str | float | int
    unit: str | None = None
    observed_at: datetime | None = None


class RiskEvent(BaseModel):
    """Risk engine(A3~A5)이 만든 위험 판정. alert 모드의 입력이기도 하다."""
    disaster: DisasterType
    level: RiskLevel
    location: Location
    radius_m: int | None = None
    issued_at: datetime
    detail: dict[str, Any] = Field(default_factory=dict)


class SpecialistResult(BaseModel):
    agent: Specialist
    summary: str                         # 해당 재난에 대한 답변 조각
    risk_level: RiskLevel = RiskLevel.SAFE
    evidence: list[Evidence] = Field(default_factory=list)
    route: dict[str, Any] | None = None  # 위치/경로 agent만 사용


class ActionPlan(BaseModel):
    """행동 권고 agent의 규칙 기반 결과. LLM은 steps를 문장으로만 풀어 쓴다."""
    phase: Phase
    risk_level: RiskLevel
    steps: list[str]                     # 우선순위 순서
    guide_ids: list[str] = Field(default_factory=list)  # 인용한 ActionGuide.id
    call_emergency: bool = False         # 이동 불가 → 119 연결 버튼 표시


class CheckResult(BaseModel):
    ok: bool
    feedback: str = ""                   # 실패 시 관리자/다듬기 agent에 전달할 사유


class ActionGuide(BaseModel):
    """행동요령 원문 한 건. 원문 수집은 별도 작업(저장 형식만 여기서 정의)."""
    id: str                              # 예: "flood.during.general.01"
    disaster: DisasterType
    phase: Phase
    audience: Literal["general", "elderly", "disabled", "tourist", "fisher"] = "general"
    text: str
    source_name: str                     # 예: "포항시 재난안전"
    source_url: str
    retrieved_at: datetime | None = None


# ---------------------------------------------------------------------------
# Reducer
# ---------------------------------------------------------------------------

RESET = "__reset__"


def merge_results(
    left: list[SpecialistResult] | None,
    right: list[SpecialistResult] | str | None,
) -> list[SpecialistResult]:
    """병렬 전문 agent 결과를 누적한다. RESET을 받으면 비운다(재시도 시)."""
    if right == RESET:
        return []
    return (left or []) + (right or [])


def merge_checks(
    left: dict[str, CheckResult] | None,
    right: dict[str, CheckResult] | str | None,
) -> dict[str, CheckResult]:
    """병렬 검증(의도·환각) 결과를 합친다. RESET을 받으면 비운다."""
    if right == RESET:
        return {}
    return {**(left or {}), **(right or {})}


# ---------------------------------------------------------------------------
# 그래프 상태
# ---------------------------------------------------------------------------

class GuardianState(TypedDict, total=False):
    # 입력
    mode: Literal["chat", "alert"]
    user: UserProfile
    current_location: Location | None
    question: str | None                 # chat 모드
    risk_event: RiskEvent | None         # alert 모드
    history: list[dict[str, str]]        # 이전 대화 (role, content)

    # 관리자
    phase: Phase
    selected_agents: list[Specialist]
    manager_feedback: str                # 검증 실패 사유 (재시도 시)

    # 전문 agent → 행동 권고
    specialist_results: Annotated[list[SpecialistResult], merge_results]
    action_plan: ActionPlan | None
    draft: str                           # 검증 전 답변

    # 검증 루프 1 (의도 + 환각, 병렬)
    checks: Annotated[dict[str, CheckResult], merge_checks]
    retry_count: int                     # 최대 MAX_RETRY
    verdict: Literal["pass", "retry", "fallback"]

    # 다듬기 + 검증 루프 2
    verified_draft: str                  # 루프 1 통과 초안 (루프 2 실패 시 fallback)
    polished: str
    polish_feedback: str
    polish_retry_count: int              # 최대 MAX_POLISH_RETRY
    polish_verdict: Literal["pass", "fail", "retry", "give_up"]

    # 출력
    final_answer: str
    used_fallback: bool


MAX_RETRY = 2
MAX_POLISH_RETRY = 1
