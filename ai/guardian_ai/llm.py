"""OpenAI 호출 (2026-10-01 Gemini → OpenAI 전환).

관리자 agent의 질문 분류(B2)부터 시작한다. 이후 전문 agent·검증·다듬기 노드도 여기의 클라이언트를 쓴다.
API 키는 환경 변수 OPENAI_API_KEY (루트 .env), 모델은 OPENAI_MODEL.

흐름: 질문·사용자 정보·이전 대화 → build_prompt()로 요청 본문 작성
      → OpenAIClassifier가 SYSTEM_PROMPT와 함께 OpenAI Responses API에 보냄
      → Classification(JSON)으로 받아 호출할 전문 agent 목록을 돌려준다.
호출이 실패하면(시간 초과·키 없음 등) graph.make_manager가 키워드 분류로 대체한다.
"""

from __future__ import annotations

import os

from openai import OpenAI
from pydantic import BaseModel, Field

from .state import GuardianState, Specialist, UserProfile
from .usage import UsageTracker, get_tracker

# 가성비 기준으로 고른 모델 (가장 싼 6세대). 부족한 단계만 gpt-6.1-sol로 올린다.
DEFAULT_MODEL = "gpt-6-luna"
# 재난 상황에서 오래 기다리지 않는다. 넘으면 키워드 분류로 대체. 느린 모델로 테스트할 때만 OPENAI_TIMEOUT_MS로 늘린다.
DEFAULT_TIMEOUT_MS = 10_000
# gpt-6-luna는 추론 모델(기본 medium). 분류는 쉬운 작업이라 low로 지연을 줄인다.
CLASSIFY_REASONING_EFFORT = "low"
HISTORY_TURNS = 6          # 분류에 참고할 최근 대화 메시지 수


class Classification(BaseModel):
    """관리자 agent의 분류 결과 (OpenAI 구조화 출력 스키마).

    text_format으로 넘기면 응답이 이 형태의 JSON으로 강제된다.
    Field의 description도 모델에 전달되므로 필드 의미를 설명하는 프롬프트 역할을 한다.
    """
    agents: list[Specialist] = Field(description="호출할 전문 agent. 해당 없으면 빈 목록")
    reason: str = Field(description="선택 이유 한 문장")


# 전문 agent 역할 (docs/agent-design.md 2절과 맞춘다)
# 아래 SYSTEM_PROMPT에 "- agent이름: 역할" 목록으로 들어가 모델이 고를 기준이 된다.
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


def make_client() -> OpenAI:
    """환경 변수로 실제 OpenAI 클라이언트를 만든다. 모든 LLM 단계가 같은 규칙을 쓴다."""
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY가 없습니다. 루트 .env에 OpenAI API 키를 넣으세요.")
    timeout_ms = int(os.environ.get("OPENAI_TIMEOUT_MS") or DEFAULT_TIMEOUT_MS)
    # 응답 대기 한도. 넘으면 예외가 나고 호출한 노드가 규칙 대체(키워드 분류·템플릿 문장 등)로 넘어간다.
    # SDK 기본 재시도(2회)는 한도를 몇 배로 늘리므로 끈다 — 실패하면 바로 대체.
    return OpenAI(api_key=api_key, timeout=timeout_ms / 1000, max_retries=0)


class OpenAIClassifier:
    """관리자 agent용 질문 분류기. graph.make_manager(OpenAIClassifier())로 쓴다."""

    def __init__(self, client: OpenAI | None = None, model: str | None = None,
                 tracker: UsageTracker | None = None):
        # client를 넘기면 그대로 쓴다(테스트에서 가짜 클라이언트 주입용).
        # 안 넘기면 환경 변수로 실제 OpenAI 클라이언트를 만든다.
        self.client = client or make_client()
        # 모델 우선순위: 인자 > OPENAI_MODEL 환경 변수 > DEFAULT_MODEL
        self.model = model or os.environ.get("OPENAI_MODEL") or DEFAULT_MODEL
        self.last: Classification | None = None   # 디버깅·로그용 마지막 분류 결과
        # 호출마다 토큰·예상 비용을 누적하고 월 예산의 50·80·100%에서 경고 (usage.py)
        self.tracker = tracker or get_tracker()

    def __call__(self, state: GuardianState) -> list[Specialist]:
        """질문을 분류해 호출할 전문 agent 목록을 돌려준다. 실패하면 예외를 낸다."""
        response = self.client.responses.parse(
            model=self.model,
            instructions=SYSTEM_PROMPT,
            input=build_prompt(state),
            text_format=Classification,                       # 응답 JSON이 Classification 형태를 따르게 한다
            reasoning={"effort": CLASSIFY_REASONING_EFFORT},
            # temperature는 넣지 않는다: 추론 모델(gpt-6-luna)은 지원하지 않는다
        )
        self.tracker.record(self.model, getattr(response, "usage", None))
        # SDK가 JSON을 Classification 객체로 변환해 둔 값. 거절·형식 오류면 None이 올 수 있다.
        result = response.output_parsed
        if not isinstance(result, Classification):
            raise ValueError(f"분류 결과를 해석하지 못함: {response.output_text!r}")
        self.last = result
        return list(dict.fromkeys(result.agents))   # 중복 제거, 순서 유지


# ---------------------------------------------------------------------------
# 강수·침수 agent 문장 작성 (B3) — 근거 목록에 있는 숫자만 쓴다
# ---------------------------------------------------------------------------

class FloodAnswer(BaseModel):
    summary: str = Field(description="사용자에게 보여 줄 답변 조각 (한국어 2~4문장)")


WRITER_PROMPT = """너는 포항 구룡포 재난 대응 서비스 '구룡가디언'의 강수·침수 agent다.
주어진 근거 목록만 보고 사용자 질문에 대한 강수·침수 상황을 한국어 2~4문장으로 쓴다.

규칙:
- 숫자는 근거 목록에 있는 값과 단위를 그대로 쓴다. 계산·추정·반올림한 새 숫자를 만들지 않는다.
- 위험 단계와 특보 이름은 근거에 적힌 그대로 쓴다. 근거에 없는 특보·경보를 말하지 않는다.
- 근거에 없는 사실(다른 지역 상황, 앞으로의 예보, 피해 규모)을 지어내지 않는다.
- '확인할 수 없는 정보'가 있으면 그 정보는 지금 확인할 수 없다고 밝힌다. 그 상태에서 "안전하다"고 단정하지 않는다.
- 위치가 '구룡포읍 중심(위치 정보 없음)'이면 그 기준이라고 밝힌다.
- 행동요령(대피 방법 등)은 쓰지 않는다. 다른 agent가 공식 행동요령으로 따로 안내한다. 가까운 대피소 이름·거리는 근거에 있으면 써도 된다.
- 재검증 실패 사유가 주어지면 그 문제를 고쳐서 다시 쓴다."""


class OpenAIWriter:
    """flood.make_rain_flood_agent(writer=OpenAIWriter())로 쓴다. 실패하면 예외 → agent가 템플릿 문장으로 대체."""

    def __init__(self, client: OpenAI | None = None, model: str | None = None,
                 tracker: UsageTracker | None = None):
        self.client = client or make_client()
        self.model = model or os.environ.get("OPENAI_MODEL") or DEFAULT_MODEL
        self.tracker = tracker or get_tracker()

    def __call__(self, question: str, evidence: str, data, feedback: str = "") -> str:
        from .flood import location_text
        where = location_text(data)   # 근거 목록의 '기준 위치'와 같은 이름 (검증기와 같은 정보를 보게)
        body = [f"질문: {question or '(경고 알림 — 질문 없음)'}", f"기준 위치: {where}",
                f"침수·호우 위험 단계(판정 엔진): {data.level.value}", "근거 목록:", evidence or "(없음)"]
        if data.unavailable:
            body.append("확인할 수 없는 정보: " + ", ".join(data.unavailable))
        if feedback:
            body.append(f"재검증 실패 사유:\n{feedback}")
        response = self.client.responses.parse(
            model=self.model, instructions=WRITER_PROMPT, input="\n".join(body),
            text_format=FloodAnswer, reasoning={"effort": "low"})
        self.tracker.record(self.model, getattr(response, "usage", None))
        result = response.output_parsed
        if not isinstance(result, FloodAnswer) or not result.summary.strip():
            raise ValueError(f"답변을 해석하지 못함: {response.output_text!r}")
        return result.summary.strip()


# ---------------------------------------------------------------------------
# 환각 검증 — 내용 검사 (B3). 숫자는 verify.check_numbers가 규칙으로 이미 확인했다
# ---------------------------------------------------------------------------

class FactCheck(BaseModel):
    ok: bool = Field(description="근거와 어긋나는 주장이 하나도 없으면 true")
    issues: list[str] = Field(description="근거와 어긋나거나 근거에 없는 주장. 한 줄에 하나, 없으면 빈 목록")


CHECKER_PROMPT = """너는 재난 안내 답변의 사실 검증자다. 답변 초안의 각 주장이 근거 목록으로 뒷받침되는지 확인한다.
숫자 값은 이미 다른 단계에서 확인했으니, 숫자가 아닌 주장을 본다.

실패로 볼 것:
- 근거에 없는 특보·경보·주의보를 있다고 하거나, 특보 종류·단계·발효/해제 상태를 바꿔 말함
- 위험 단계를 근거보다 높이거나 낮춤 (예: 근거 '주의'를 '경보'로, '경보'를 '정상'으로)
- 근거에 없는 장소·시설·피해·예보를 사실처럼 말함
- 근거에서 확인할 수 없다고 한 정보를 두고 "안전하다"고 단정함
- 관측소·지명을 다른 것과 바꿔 말함

실패가 아닌 것: 표현을 쉽게 바꾸기, 근거 일부만 고르기, "확인할 수 없다"고 밝히기, 일반적인 주의 당부.
issues에는 무엇이 근거와 어떻게 다른지 짧게 쓴다."""


class OpenAIFactChecker:
    """verify.make_hallucination_check(checker=OpenAIFactChecker())로 쓴다.

    모델은 OPENAI_VERIFY_MODEL(없으면 OPENAI_MODEL). 검증만 gpt-6.1-sol로 올릴 때 이 값만 바꾼다.
    """

    def __init__(self, client: OpenAI | None = None, model: str | None = None,
                 tracker: UsageTracker | None = None, reasoning_effort: str = "medium"):
        self.client = client or make_client()
        self.model = (model or os.environ.get("OPENAI_VERIFY_MODEL") or os.environ.get("OPENAI_MODEL")
                      or DEFAULT_MODEL)
        self.tracker = tracker or get_tracker()
        # 검증은 놓치면 안 되므로 분류(low)보다 깊게 생각하게 둔다
        self.reasoning_effort = reasoning_effort

    def __call__(self, draft: str, evidence: str):
        from .state import CheckResult
        response = self.client.responses.parse(
            model=self.model, instructions=CHECKER_PROMPT,
            input=f"근거 목록:\n{evidence}\n\n답변 초안:\n{draft}",
            text_format=FactCheck, reasoning={"effort": self.reasoning_effort})
        self.tracker.record(self.model, getattr(response, "usage", None))
        result = response.output_parsed
        if not isinstance(result, FactCheck):
            raise ValueError(f"검증 결과를 해석하지 못함: {response.output_text!r}")
        if result.ok:   # ok=true인데 issues가 있으면 사소한 메모로 보고 통과 (오탐으로 안전 안내까지 가지 않게)
            return CheckResult(ok=True)
        return CheckResult(ok=False, feedback="근거와 다른 내용: " + " / ".join(result.issues or ["(사유 없음)"]))
