"""실시간 음성 대화 (2026-10-11): OpenAI Realtime(`gpt-realtime-2`)이 듣고 말하고, 답 내용은 LangGraph가 만든다.

- 앱(웹)은 OpenAI와 WebRTC로 직접 연결한다. 진짜 API 키는 서버만 갖고, 앱에는 10분짜리 임시 키만 준다 (`POST /api/voice/session`).
- Realtime 모델은 스스로 답하지 않는다: 세션 `tool_choice=required`라 사용자가 말할 때마다 도구만 부른다.
  `ask_guardian(question)` → 앱이 `/api/chat`(LangGraph 전체: 분류·전문 agent·행동 권고·환각 검증)을 부르고, 그 답의 음성 문장을
  "그대로 읽어라"는 지시와 함께 돌려준다. `end_conversation()` → 사용자가 끝내자고 함.
- 그래서 근거·검증은 글 채팅과 같다. 다만 소리로 나가는 말은 모델이 읽는 것이라 검증 밖이다 — 화면의 글 답이 기준.
- Realtime 사용료는 앱과 OpenAI가 직접 주고받아 `usage.py` 예상 비용에 잡히지 않는다.

시각장애인 대피 확인 (B12, 2026-10-12): 같은 임시 키 방식으로 세션 두 가지를 더 만든다 (`POST /api/voice/evac-session`).
- `evac_check`: 대피 경보가 울리면 세 가지(대피 완료·대피 중·도움 필요) 중 하나를 묻고 `set_evacuation_status`로 받는다.
  저장은 앱이 서버 `POST /api/v1/alerts/{id}/response`(via=voice)로 한다 — 이 모듈은 저장하지 않는다.
- `announce`: 방재단원 도착 예상 시간 같은 정해진 문장을 한 번 읽고 끝낸다.
- 이 흐름은 Google 음성(voice.py)을 쓰지 않는다. 듣기·말하기 모두 Realtime.
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
STATUS_TOOL = "set_evacuation_status"
EVAC_STATUSES = ("evacuated", "evacuating", "need_help")   # 서버 ButtonStatus와 같은 값
EVAC_MODES = ("evac_check", "announce")

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


EVAC_CHECK_INSTRUCTIONS = """너는 구룡포 재난 안내 서비스 '구룡가디언'의 음성 안내다. 한국어로만, 천천히 또박또박 짧게 말한다.
상대는 앞이 잘 보이지 않는 주민이고, 방금 대피 경보가 울려 휴대폰 화면을 볼 수 없는 상태일 수 있다.

순서:
1. 대화가 시작되면 먼저 이렇게 말한다: "{alert} 지금 바로 대피해야 합니다. 지금 상태를 말씀해 주세요. 대피 완료, 대피 중, 도움 필요 중에서 하나를 말씀해 주세요."
2. 주민의 대답을 세 가지 중 하나로 정한다.
   - evacuated(대피 완료): "다 왔어요", "대피소에 있어요", "안전한 곳에 도착했어요"
   - evacuating(대피 중): "가고 있어요", "나가는 중이에요", "지금 이동 중"
   - need_help(도움 필요): "도와주세요", "못 움직여요", "혼자 못 가요", "다쳤어요", 비명이나 다급한 말
3. 정해지면 바로 set_evacuation_status 도구를 부른다. transcript에는 주민이 한 말을 그대로 적는다.
4. 대답이 세 가지 중 어느 것인지 알 수 없으면 한 번만 다시 묻는다: "대피 완료, 대피 중, 도움 필요 중에서 말씀해 주세요."
   두 번째도 알 수 없거나 위험해 보이면 need_help로 정한다.
5. 도구 결과로 받은 문장은 한 글자도 바꾸지 않고 그대로 읽는다. 그 뒤 end_conversation을 부른다.
6. 재난 정보·대피소·경로를 스스로 지어내 말하지 않는다."""

ANNOUNCE_INSTRUCTIONS = """너는 구룡포 재난 안내 서비스 '구룡가디언'의 음성 안내다. 한국어로만 말한다.
대화가 시작되면 아래 문장을 한 글자도 바꾸지 않고 천천히 한 번 읽는다. 덧붙이지 않는다. 다 읽으면 end_conversation을 부른다.

읽을 문장:
{text}"""

STATUS_TOOL_DEF: dict[str, Any] = {
    "type": "function", "name": STATUS_TOOL,
    "description": "주민이 말한 대피 상태를 저장한다. 세 가지 중 하나로 정해졌을 때 한 번 부른다.",
    "parameters": {"type": "object", "additionalProperties": False, "required": ["status", "transcript"],
                   "properties": {"status": {"type": "string", "enum": list(EVAC_STATUSES),
                                             "description": "evacuated=대피 완료, evacuating=대피 중, need_help=도움 필요"},
                                  "transcript": {"type": "string", "description": "주민이 한 말 그대로 (한국어)"}}}}
END_TOOL_DEF: dict[str, Any] = {
    "type": "function", "name": END_TOOL,
    "description": "안내를 마쳤을 때 부른다.",
    "parameters": {"type": "object", "additionalProperties": False, "properties": {}}}


def read_out_instructions(text: str) -> str:
    """도구 결과를 받은 뒤 앱이 보내는 `response.create`의 지시 — 답의 음성 문장을 그대로 읽게 한다 (앱이 같은 문구를 쓴다)."""
    return "다음 문장을 한 글자도 바꾸지 않고 그대로 읽어라. 덧붙이지 마라.\n\n" + text


class RealtimeUnavailable(Exception):
    """OpenAI 키가 없거나 임시 키를 받지 못함 → 503"""


def session_config(model: str | None = None, voice: str | None = None) -> dict[str, Any]:
    """Realtime 세션 설정. 말 끝은 모델이 뜻으로 판단(semantic_vad)하고, 사용자가 끼어들면 하던 말을 멈춘다."""
    return _base_config(INSTRUCTIONS, TOOLS, "required", model, voice)


def evac_session_config(mode: str, alert_text: str = "", announce_text: str = "",
                        model: str | None = None, voice: str | None = None) -> dict[str, Any]:
    """시각장애인 대피 확인(evac_check) / 정해진 문장 안내(announce) 세션 설정."""
    if mode == "evac_check":
        alert = (alert_text.strip().rstrip(".") + ".") if alert_text.strip() else "대피 경보입니다."
        return _base_config(EVAC_CHECK_INSTRUCTIONS.format(alert=alert), [STATUS_TOOL_DEF, END_TOOL_DEF], "auto", model, voice)
    if mode == "announce":
        if not announce_text.strip():
            raise ValueError("읽을 문장이 없습니다")
        c = _base_config(ANNOUNCE_INSTRUCTIONS.format(text=announce_text.strip()), [END_TOOL_DEF], "auto", model, voice)
        c["audio"]["input"]["turn_detection"]["create_response"] = False   # 듣지 않고 읽기만 한다
        return c
    raise ValueError(f"모르는 mode: {mode}")


def _base_config(instructions: str, tools: list[dict[str, Any]], tool_choice: str,
                 model: str | None, voice: str | None) -> dict[str, Any]:
    return {
        "type": "realtime",
        "model": model or os.environ.get("OPENAI_REALTIME_MODEL") or DEFAULT_MODEL,
        "instructions": instructions,
        "output_modalities": ["audio"],
        "audio": {
            "input": {"transcription": {"model": "gpt-4o-mini-transcribe", "language": "ko"},
                      "noise_reduction": {"type": "near_field"},
                      "turn_detection": {"type": "semantic_vad", "create_response": True, "interrupt_response": True}},
            "output": {"voice": voice or os.environ.get("OPENAI_REALTIME_VOICE") or DEFAULT_VOICE},
        },
        "tools": tools,
        "tool_choice": tool_choice,
    }


def create_client_secret(http: httpx.Client | None = None, api_key: str | None = None) -> dict[str, Any]:
    """앱에 줄 임시 키를 OpenAI에서 받는다. 돌려주는 값: client_secret·expires_at·model·calls_url·도구 이름."""
    config = session_config()
    data = _request_secret(config, http, api_key)
    return {"client_secret": data["value"], "expires_at": data.get("expires_at"), "model": config["model"],
            "calls_url": CALLS_URL, "ask_tool": ASK_TOOL, "end_tool": END_TOOL,
            "read_out_prefix": read_out_instructions("")}


def create_evac_client_secret(mode: str, alert_text: str = "", announce_text: str = "",
                              http: httpx.Client | None = None, api_key: str | None = None) -> dict[str, Any]:
    """대피 확인·안내 세션 임시 키. ValueError는 잘못된 요청(422), RealtimeUnavailable은 503."""
    config = evac_session_config(mode, alert_text=alert_text, announce_text=announce_text)
    data = _request_secret(config, http, api_key)
    return {"client_secret": data["value"], "expires_at": data.get("expires_at"), "model": config["model"],
            "calls_url": CALLS_URL, "mode": mode, "status_tool": STATUS_TOOL, "end_tool": END_TOOL,
            "statuses": list(EVAC_STATUSES), "read_out_prefix": read_out_instructions("")}


def _request_secret(config: dict[str, Any], http: httpx.Client | None, api_key: str | None) -> dict[str, Any]:
    key = api_key if api_key is not None else (os.environ.get("OPENAI_API_KEY") or "").strip()
    if not key:
        raise RealtimeUnavailable("OPENAI_API_KEY가 없습니다")
    try:
        res = (http or httpx).post(CLIENT_SECRETS_URL, headers={"Authorization": f"Bearer {key}"}, timeout=TIMEOUT_S,
                                   json={"expires_after": {"anchor": "created_at", "seconds": SECRET_TTL_S}, "session": config})
    except httpx.HTTPError as e:
        raise RealtimeUnavailable(f"OpenAI에 연결하지 못했습니다 ({type(e).__name__})") from e
    if res.status_code != 200:
        logger.warning("Realtime 임시 키 오류 %s %s", res.status_code, res.text[:200])
        raise RealtimeUnavailable(f"OpenAI 오류 (HTTP {res.status_code})")
    return res.json()
