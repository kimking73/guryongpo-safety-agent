"""실시간 음성 대화 (2026-10-11): OpenAI Realtime(`gpt-realtime-2`)이 듣고 말하고, 답 내용은 LangGraph가 만든다.

- 앱(웹)은 OpenAI와 WebRTC로 직접 연결한다. 진짜 API 키는 서버만 갖고, 앱에는 10분짜리 임시 키만 준다 (`POST /api/voice/session`).
- Realtime 모델은 스스로 답하지 않는다: 세션 `tool_choice=required`라 사용자가 말할 때마다 도구만 부른다.
  `ask_guardian(question)` → 앱이 `/api/chat`(LangGraph 전체: 분류·전문 agent·행동 권고·환각 검증)을 부르고, 그 답의 음성 문장을
  "그대로 읽어라"는 지시와 함께 돌려준다. `end_conversation()` → 사용자가 끝내자고 함.
- 그래서 근거·검증은 글 채팅과 같다. 다만 소리로 나가는 말은 모델이 읽는 것이라 검증 밖이다 — 화면의 글 답이 기준.
- Realtime 사용료는 앱과 OpenAI가 직접 주고받아 `usage.py` 예상 비용에 잡히지 않는다.
"""

from __future__ import annotations

import logging
import os
from typing import Any

import httpx

logger = logging.getLogger(__name__)

CLIENT_SECRETS_URL = "https://api.openai.com/v1/realtime/client_secrets"
# 앱이 SDP를 보내는 주소 (WebRTC). 모델은 임시 키의 세션 설정을 따른다
CALLS_URL = "https://api.openai.com/v1/realtime/calls"
DEFAULT_MODEL = "gpt-realtime-2"
DEFAULT_VOICE = "marin"
SECRET_TTL_S = 600               # 임시 키로 연결을 시작할 수 있는 시간. 연결된 대화는 그 뒤에도 이어진다
TIMEOUT_S = 10.0
ASK_TOOL = "ask_guardian"
END_TOOL = "end_conversation"

INSTRUCTIONS = """너는 구룡포 재난 안내 서비스 '구룡가디언'의 음성 창구 '모리'다. 한국어로만 말한다.
너는 재난·날씨·대피소·경로·지원 제도에 대해 아는 것이 없다. 네가 아는 내용으로 답하면 안 된다.

규칙:
1. 사용자가 무엇이든 묻거나 말하면 반드시 ask_guardian 도구를 부른다. question에는 사용자가 한 말을 뜻을 바꾸지 않고 그대로 적는다.
   앞 대화를 가리키는 말("거기", "그럼")도 고치지 말고 그대로 적는다 — 대화 기억은 도구 쪽에 있다.
2. 사용자가 대화를 끝내자고 하면("그만", "대화 종료", "끝낼게", "됐어") end_conversation 도구를 부른다.
   "그만 대피해도 돼?"처럼 질문이면 끝내는 말이 아니다.
3. 소리가 불분명해도 들린 대로 question에 적어 ask_guardian을 부른다. 스스로 되묻거나 추측해 답하지 않는다.
4. 도구를 부르기 전에는 "네, 확인해 볼게요."처럼 아주 짧게 한마디만 할 수 있다. 재난·장소·숫자에 대한 내용은 말하지 않는다.
5. 읽으라고 받은 문장은 한 글자도 바꾸지 않고 그대로 읽는다. 숫자·장소 이름·단위를 바꾸거나 덧붙이지 않는다."""

TOOLS: list[dict[str, Any]] = [
    {"type": "function", "name": ASK_TOOL,
     "description": "사용자의 질문·말을 구룡가디언 AI에 전달해 답을 받는다. 사용자가 말할 때마다 부른다.",
     "parameters": {"type": "object", "additionalProperties": False, "required": ["question"],
                    "properties": {"question": {"type": "string", "description": "사용자가 한 말 그대로 (한국어)"}}}},
    {"type": "function", "name": END_TOOL,
     "description": "사용자가 음성 대화를 끝내자고 했을 때 부른다.",
     "parameters": {"type": "object", "additionalProperties": False, "properties": {}}},
]


def read_out_instructions(text: str) -> str:
    """도구 결과를 받은 뒤 앱이 보내는 `response.create`의 지시 — 답의 음성 문장을 그대로 읽게 한다 (앱이 같은 문구를 쓴다)."""
    return "다음 문장을 한 글자도 바꾸지 않고 그대로 읽어라. 덧붙이지 마라.\n\n" + text


class RealtimeUnavailable(Exception):
    """OpenAI 키가 없거나 임시 키를 받지 못함 → 503"""


def session_config(model: str | None = None, voice: str | None = None) -> dict[str, Any]:
    """Realtime 세션 설정. 말 끝은 모델이 뜻으로 판단(semantic_vad)하고, 사용자가 끼어들면 하던 말을 멈춘다."""
    return {
        "type": "realtime",
        "model": model or os.environ.get("OPENAI_REALTIME_MODEL") or DEFAULT_MODEL,
        "instructions": INSTRUCTIONS,
        "output_modalities": ["audio"],
        "audio": {
            "input": {"transcription": {"model": "gpt-4o-mini-transcribe", "language": "ko"},
                      "noise_reduction": {"type": "near_field"},
                      "turn_detection": {"type": "semantic_vad", "create_response": True, "interrupt_response": True}},
            "output": {"voice": voice or os.environ.get("OPENAI_REALTIME_VOICE") or DEFAULT_VOICE},
        },
        "tools": TOOLS,
        "tool_choice": "required",
    }


def create_client_secret(http: httpx.Client | None = None, api_key: str | None = None) -> dict[str, Any]:
    """앱에 줄 임시 키를 OpenAI에서 받는다. 돌려주는 값: client_secret·expires_at·model·calls_url·도구 이름."""
    key = api_key if api_key is not None else (os.environ.get("OPENAI_API_KEY") or "").strip()
    if not key:
        raise RealtimeUnavailable("OPENAI_API_KEY가 없습니다")
    config = session_config()
    try:
        res = (http or httpx).post(CLIENT_SECRETS_URL, headers={"Authorization": f"Bearer {key}"}, timeout=TIMEOUT_S,
                                   json={"expires_after": {"anchor": "created_at", "seconds": SECRET_TTL_S}, "session": config})
    except httpx.HTTPError as e:
        raise RealtimeUnavailable(f"OpenAI에 연결하지 못했습니다 ({type(e).__name__})") from e
    if res.status_code != 200:
        logger.warning("Realtime 임시 키 오류 %s %s", res.status_code, res.text[:200])
        raise RealtimeUnavailable(f"OpenAI 오류 (HTTP {res.status_code})")
    data = res.json()
    return {"client_secret": data["value"], "expires_at": data.get("expires_at"), "model": config["model"],
            "calls_url": CALLS_URL, "ask_tool": ASK_TOOL, "end_tool": END_TOOL,
            "read_out_prefix": read_out_instructions("")}
