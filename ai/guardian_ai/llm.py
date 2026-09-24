"""Gemini 호출.

관리자 agent의 질문 분류(B2)부터 시작한다. 이후 전문 agent·검증·다듬기 노드도 여기의 클라이언트를 쓴다.
API 키는 환경 변수 GEMINI_API_KEY (루트 .env), 모델은 GEMINI_MODEL.
"""

from __future__ import annotations

import os

from google import genai
from google.genai import types
from pydantic import BaseModel, Field

from .state import GuardianState, Specialist, UserProfile

DEFAULT_MODEL = "gemini-3.6-flash"
TIMEOUT_MS = 10_000        # 재난 상황에서 오래 기다리지 않는다. 넘으면 키워드 분류로 대체
HISTORY_TURNS = 6          # 분류에 참고할 최근 대화 메시지 수


class Classification(BaseModel):
    """관리자 agent의 분류 결과 (Gemini 구조화 출력 스키마)."""
    agents: list[Specialist] = Field(description="호출할 전문 agent. 해당 없으면 빈 목록")
    reason: str = Field(description="선택 이유 한 문장")


# 전문 agent 역할 (docs/agent-design.md 2절과 맞춘다)
_AGENT_ROLES = {
    Specialist.LANDSLIDE: "산사태 위험지역, 토사 붕괴, 산 근처 안전",
    Specialist.RAIN_FLOOD: "비·호우·강수량, 침수·수위, 만조와 겹친 침수",
    Specialist.WIND_TYPHOON: "강풍·태풍·파도·너울, 선박·어업 피해 대비",
    Specialist.LIFE_SAFETY: "미세먼지·초미세먼지·자외선 등 생활안전 정보",
    Specialist.LOCATION_ROUTE: "사용자 위치의 위험 여부, 대피소 위치, 이동·대피 경로 안내, '가도 되나요' 같은 이동 판단",
}

SYSTEM_PROMPT = f"""너는 포항 구룡포 재난 대응 서비스 '구룡가디언'의 관리자 agent다.
사용자 질문을 읽고, 답하는 데 필요한 전문 agent만 고른다. 답변 자체는 쓰지 않는다.

전문 agent:
{chr(10).join(f"- {s.value}: {role}" for s, role in _AGENT_ROLES.items())}

규칙:
- 필요한 agent를 모두 고르되, 관련 없는 agent는 넣지 않는다.
- 이동·외출·대피 여부를 묻는 질문은 해당 재난 agent와 location_route_agent를 함께 고른다.
- "지금 뭘 해야 하나요?"처럼 재난 종류가 없는 상황 질문은 산사태·강수침수·강풍태풍 agent를 모두 고른다.
- 인사, 서비스 사용법 등 재난·안전과 무관한 질문은 빈 목록.
- 이전 대화가 있으면 지시어("거기", "그럼")를 이전 대화로 해석한다.
- 재검증 실패 사유가 주어지면, 그 사유를 해결하도록 선택을 조정한다."""


def _profile_line(user: UserProfile | None) -> str:
    if user is None:
        return "정보 없음"
    parts = ["주민" if user.user_type == "resident" else "관광객"]
    if user.age:
        parts.append(f"{user.age}세")
    if user.mobility:
        parts.append(f"이동수단 {user.mobility.value}")
    if user.walking_impaired:
        parts.append("보행 불편")
    if user.has_dependents:
        parts.append("보호가 필요한 동반자 있음")
    if user.occupation:
        parts.append(f"직업 {user.occupation}")
    return ", ".join(parts)


def build_prompt(state: GuardianState) -> str:
    """분류 요청 본문. 테스트에서 프롬프트 내용을 확인할 수 있게 분리했다."""
    lines = [f"사용자: {_profile_line(state.get('user'))}"]
    history = (state.get("history") or [])[-HISTORY_TURNS:]
    if history:
        lines.append("이전 대화:")
        lines += [f"- {m.get('role')}: {m.get('content')}" for m in history]
    if state.get("manager_feedback"):
        lines.append(f"재검증 실패 사유:\n{state['manager_feedback']}")
    lines.append(f"질문: {state.get('question') or ''}")
    return "\n".join(lines)


class GeminiClassifier:
    """관리자 agent용 질문 분류기. graph.make_manager(GeminiClassifier())로 쓴다."""

    def __init__(self, client: genai.Client | None = None, model: str | None = None):
        if client is None:
            api_key = os.environ.get("GEMINI_API_KEY")
            if not api_key:
                raise RuntimeError("GEMINI_API_KEY가 없습니다. 루트 .env에 AI Studio 키를 넣으세요.")
            client = genai.Client(api_key=api_key, http_options=types.HttpOptions(timeout=TIMEOUT_MS))
        self.client = client
        self.model = model or os.environ.get("GEMINI_MODEL") or DEFAULT_MODEL
        self.last: Classification | None = None   # 디버깅·로그용 마지막 분류 결과

    def __call__(self, state: GuardianState) -> list[Specialist]:
        response = self.client.models.generate_content(
            model=self.model,
            contents=build_prompt(state),
            config=types.GenerateContentConfig(
                system_instruction=SYSTEM_PROMPT,
                response_mime_type="application/json",
                response_schema=Classification,
                temperature=0,
            ),
        )
        result = response.parsed
        if not isinstance(result, Classification):
            raise ValueError(f"분류 결과를 해석하지 못함: {response.text!r}")
        self.last = result
        return list(dict.fromkeys(result.agents))   # 중복 제거, 순서 유지
