"""Gemini 호출.

관리자 agent의 질문 분류(B2)부터 시작한다. 이후 전문 agent·검증·다듬기 노드도 여기의 클라이언트를 쓴다.
API 키는 환경 변수 GEMINI_API_KEY (루트 .env), 모델은 GEMINI_MODEL.

흐름: 질문·사용자 정보·이전 대화 → build_prompt()로 요청 본문 작성
      → GeminiClassifier가 SYSTEM_PROMPT와 함께 Gemini에 보냄
      → Classification(JSON)으로 받아 호출할 전문 agent 목록을 돌려준다.
호출이 실패하면(시간 초과·키 없음 등) graph.make_manager가 키워드 분류로 대체한다.
"""

from __future__ import annotations

import os

from google import genai
from google.genai import types
from pydantic import BaseModel, Field

from .state import GuardianState, Specialist, UserProfile

DEFAULT_MODEL = "gemini-3.6-flash"
# 재난 상황에서 오래 기다리지 않는다. 넘으면 키워드 분류로 대체. 느린 모델로 테스트할 때만 GEMINI_TIMEOUT_MS로 늘린다.
DEFAULT_TIMEOUT_MS = 10_000
HISTORY_TURNS = 6          # 분류에 참고할 최근 대화 메시지 수


class Classification(BaseModel):
    """관리자 agent의 분류 결과 (Gemini 구조화 출력 스키마).

    Gemini에 response_schema로 넘기면 응답이 이 형태의 JSON으로 강제된다.
    Field의 description도 모델에 전달되므로 필드 의미를 설명하는 프롬프트 역할을 한다.
    """
    agents: list[Specialist] = Field(description="호출할 전문 agent. 해당 없으면 빈 목록")
    reason: str = Field(description="선택 이유 한 문장")


# 전문 agent 역할 (docs/agent-design.md 2절과 맞춘다)
# 아래 SYSTEM_PROMPT에 "- agent이름: 역할" 목록으로 들어가 Gemini가 고를 기준이 된다.
_AGENT_ROLES = {
    Specialist.LANDSLIDE: "산사태 위험지역, 토사 붕괴, 산 근처 안전",
    Specialist.RAIN_FLOOD: "비·호우·강수량, 침수·수위, 만조와 겹친 침수",
    Specialist.WIND_TYPHOON: "강풍·태풍·파도·너울, 선박·어업 피해 대비",
    Specialist.LIFE_SAFETY: "미세먼지·초미세먼지·자외선 등 생활안전 정보",
    Specialist.LOCATION_ROUTE: "사용자 위치의 위험 여부, 대피소 위치, 이동·대피 경로 안내, '가도 되나요' 같은 이동 판단",
}

# 모든 요청에 공통으로 붙는 시스템 지시문. 질문마다 달라지는 내용은 build_prompt()가 만든다.
# chr(10)은 줄바꿈("\n"). f-string 중괄호 안에는 백슬래시를 쓸 수 없어서 이렇게 썼다.
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
    """사용자 정보를 한 줄 요약으로 바꾼다. 예: "관광객, 72세, 이동수단 도보, 보행 불편"

    이동 판단(location_route_agent 선택 등)에 쓰이도록 프롬프트에 넣는다.
    값이 있는 항목만 붙인다.
    """
    if user is None:
        return "정보 없음"
    # 사용자 유형은 항상 있다: resident면 주민, 그 외는 관광객
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
    # 결과 예:
    #   사용자: 주민, 70세
    #   이전 대화:
    #   - user: 구룡포항 괜찮아요?
    #   - assistant: ...
    #   질문: 그럼 거기 가도 돼요?
    lines = [f"사용자: {_profile_line(state.get('user'))}"]
    # 지시어("거기", "그럼") 해석용. 토큰·지연을 줄이려고 최근 HISTORY_TURNS개만 넣는다.
    history = (state.get("history") or [])[-HISTORY_TURNS:]
    if history:
        lines.append("이전 대화:")
        lines += [f"- {m.get('role')}: {m.get('content')}" for m in history]
    # 검증 단계에서 되돌아온 경우(재시도)에만 있다. 실패 사유를 보고 agent 선택을 고치게 한다.
    if state.get("manager_feedback"):
        lines.append(f"재검증 실패 사유:\n{state['manager_feedback']}")
    lines.append(f"질문: {state.get('question') or ''}")
    return "\n".join(lines)


class GeminiClassifier:
    """관리자 agent용 질문 분류기. graph.make_manager(GeminiClassifier())로 쓴다."""

    def __init__(self, client: genai.Client | None = None, model: str | None = None):
        # client를 넘기면 그대로 쓴다(테스트에서 가짜 클라이언트 주입용).
        # 안 넘기면 환경 변수로 실제 Gemini 클라이언트를 만든다.
        if client is None:
            api_key = os.environ.get("GEMINI_API_KEY")
            if not api_key:
                raise RuntimeError("GEMINI_API_KEY가 없습니다. 루트 .env에 AI Studio 키를 넣으세요.")
            timeout_ms = int(os.environ.get("GEMINI_TIMEOUT_MS") or DEFAULT_TIMEOUT_MS)
            # 응답 대기 한도. 넘으면 예외가 나고 graph 쪽에서 키워드 분류로 넘어간다.
            client = genai.Client(api_key=api_key, http_options=types.HttpOptions(timeout=timeout_ms))
        self.client = client
        # 모델 우선순위: 인자 > GEMINI_MODEL 환경 변수 > DEFAULT_MODEL
        self.model = model or os.environ.get("GEMINI_MODEL") or DEFAULT_MODEL
        self.last: Classification | None = None   # 디버깅·로그용 마지막 분류 결과

    def __call__(self, state: GuardianState) -> list[Specialist]:
        """질문을 분류해 호출할 전문 agent 목록을 돌려준다. 실패하면 예외를 낸다."""
        response = self.client.models.generate_content(
            model=self.model,
            contents=build_prompt(state),
            config=types.GenerateContentConfig(
                system_instruction=SYSTEM_PROMPT,
                response_mime_type="application/json",   # JSON으로만 답하게 하고
                response_schema=Classification,          # 그 JSON이 Classification 형태를 따르게 한다
                temperature=0,                           # 같은 질문엔 같은 분류가 나오도록 무작위성 최소화
            ),
        )
        # SDK가 JSON을 Classification 객체로 변환해 둔 값. 형식이 어긋나면 None이 올 수 있다.
        result = response.parsed
        if not isinstance(result, Classification):
            raise ValueError(f"분류 결과를 해석하지 못함: {response.text!r}")
        self.last = result
        return list(dict.fromkeys(result.agents))   # 중복 제거, 순서 유지
