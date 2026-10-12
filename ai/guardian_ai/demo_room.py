"""시연 방 (2026-10-12 사용자 요청): 다른 계정·다른 브라우저·다른 기기의 사용자 모드 창과 방재단원 모드 창을 잇는다.

앱 시연 모드의 대피 상황은 기기 안에만 있어(같은 브라우저 창끼리만 공유) 계정이 다르면 전달되지 않았다.
같은 '시연 코드'를 넣은 창끼리 이 방을 2초마다 주고받는다.

- 사용자 모드가 쓰는 것: 시연 경보 진행 여부(alert_active) · 대피 응답(response) · 장애 유형(needs)
- 방재단원 모드가 쓰는 것: 출동 기록(dispatch: 출발 시각 · 도착 예정 · 단계)

시연용이라 메모리에만 둔다 (재시작하면 비워짐) — 이름·주소·위치·연락처 같은 개인정보는 받지 않는다.
"""

from __future__ import annotations

import threading
import time
from typing import Literal, Optional

from pydantic import BaseModel, Field

CODE_PATTERN = r"^[A-Z0-9]{4,8}$"
TTL_S = 6 * 3600          # 마지막으로 바뀐 뒤 6시간 지나면 지운다
MAX_ROOMS = 200           # 넘치면 가장 오래된 방부터 지운다

Response = Literal["need_help", "evacuating", "evacuated"]
Need = Literal["vision", "hearing", "mobility_limited"]


class DemoDispatch(BaseModel):
    departed_at: str = Field(max_length=40)
    eta: str = Field(max_length=40)
    responder: str = Field(default="시연 방재단원", max_length=40)
    stage: Literal["en_route", "visiting", "done"] = "en_route"


class DemoRoomPatch(BaseModel):
    """보낸 칸만 바꾼다 (보내지 않은 칸은 그대로). null 을 보내면 그 칸을 비운다"""
    alert_active: Optional[bool] = None
    response: Optional[Response] = None
    needs: Optional[list[Need]] = Field(default=None, max_length=3)
    dispatch: Optional[DemoDispatch] = None


class DemoRoom(BaseModel):
    code: str
    alert_active: bool = False
    response: Optional[Response] = None
    needs: list[Need] = Field(default_factory=list)
    dispatch: Optional[DemoDispatch] = None
    version: int = 0          # 바뀔 때마다 1씩 — 앱이 같은 상태를 두 번 반영하지 않게
    updated_at: float = 0.0


class DemoRooms:
    def __init__(self, clock=time.time):
        self._rooms: dict[str, DemoRoom] = {}
        self._lock = threading.Lock()
        self._clock = clock

    def _sweep(self) -> None:
        now = self._clock()
        for code in [c for c, r in self._rooms.items() if now - r.updated_at > TTL_S]:
            del self._rooms[code]
        while len(self._rooms) > MAX_ROOMS:
            del self._rooms[min(self._rooms, key=lambda c: self._rooms[c].updated_at)]

    def get(self, code: str) -> DemoRoom:
        with self._lock:
            self._sweep()
            return (self._rooms.get(code) or DemoRoom(code=code)).model_copy(deep=True)

    def patch(self, code: str, patch: DemoRoomPatch) -> DemoRoom:
        sent = patch.model_fields_set
        with self._lock:
            room = self._rooms.get(code) or DemoRoom(code=code)
            if "alert_active" in sent:
                room.alert_active = bool(patch.alert_active)
            if "response" in sent:
                room.response = patch.response
            if "needs" in sent:
                room.needs = list(dict.fromkeys(patch.needs or []))
            if "dispatch" in sent:
                room.dispatch = patch.dispatch
            room.version += 1
            room.updated_at = self._clock()
            self._rooms[code] = room
            self._sweep()
            return room.model_copy(deep=True)
