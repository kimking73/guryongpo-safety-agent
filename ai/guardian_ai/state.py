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
    """DB hazard_type과 같은 값 (db/init/01_schema.sql)."""
    LANDSLIDE = "landslide"      # 산사태
    HEAVY_RAIN = "heavy_rain"    # 호우
    FLOOD = "flood"              # 침수
    STRONG_WIND = "strong_wind"  # 강풍
    TYPHOON = "typhoon"          # 태풍
    HIGH_SEAS = "high_seas"      # 풍랑 (어업·해안)
    FINE_DUST = "fine_dust"      # 미세먼지 (생활안전)
    ULTRAFINE_DUST = "ultrafine_dust"  # 초미세먼지 (생활안전)
    UV = "uv"                    # 자외선 (생활안전)


class Phase(str, Enum):
    """행동 권고 판단 트리의 첫 분기."""
    BEFORE = "before"  # 재난 전: 예보·주의보 예정
    DURING = "during"  # 재난 중: 특보 발효 또는 위험 판정
    AFTER = "after"    # 재난 후: 특보 해제 후 일정 시간
    NONE = "none"      # 평시


class RiskLevel(str, Enum):
    """DB risk_level과 같은 5단계 (A의 판정 엔진·특보와 공통). 순서대로 높아진다."""
    NORMAL = "normal"      # 정상
    WATCH = "watch"        # 관심 · 예비특보
    ADVISORY = "advisory"  # 주의 · 주의보
    WARNING = "warning"    # 경계 · 경보
    CRITICAL = "critical"  # 심각 · 위험

    @property
    def rank(self) -> int:
        return list(RiskLevel).index(self)


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
    risk_level: RiskLevel = RiskLevel.NORMAL
    evidence: list[Evidence] = Field(default_factory=list)
    route: dict[str, Any] | None = None  # 위치/경로 agent만 사용


class ActionPlan(BaseModel):
    """행동 권고 agent의 규칙 기반 결과. LLM은 steps를 문장으로만 풀어 쓴다."""
    phase: Phase
    risk_level: RiskLevel
    steps: list[str]                     # 우선순위 순서
    guide_ids: list[int] = Field(default_factory=list)  # 인용한 ActionGuide.id
    call_emergency: bool = False         # 이동 불가 → 119 연결 버튼 표시
    evidence: list[Evidence] = Field(default_factory=list)  # 인용한 원문(·119 권고) — 환각 검증이 '지금 할 일'을 대조한다


class CheckResult(BaseModel):
    ok: bool
    feedback: str = ""                   # 실패 시 관리자/다듬기 agent에 전달할 사유


class ActionGuide(BaseModel):
    """행동요령 원문 한 건 = DB action_guides 한 행 (A7이 적재). 행동 권고 agent는 이 문장만 인용한다."""
    id: int
    disaster: DisasterType               # DB 컬럼 이름은 hazard
    phase: Phase                         # before / during / after
    min_level: RiskLevel                 # 이 단계 이상일 때 보여 준다
    targets: list[str]                   # all, resident, tourist, fisher, vessel_owner, coastal, farmer, driver
    priority: int                        # 낮을수록 먼저
    title: str
    content: str
    voice_text: str | None = None        # 음성 안내용 짧은 문장 (B5)
    source_name: str                     # 예: "포항시 재난안전 홈페이지"
    source_url: str | None = None


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
    user_memory: list[str]               # 사용자 기억 — 지난 대화들에서 사용자가 말한 사실·대화 요약 (memory.py)

    # 관리자
    phase: Phase
    selected_agents: list[Specialist]
    manager_feedback: str                # 검증 실패 사유 (재시도 시)
    destination_query: str | None        # 질문에서 뽑은 목적지 이름 ("구룡포항", "집"). 없으면 가까운 대피소로 안내

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
