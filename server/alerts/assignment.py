"""방재단 배정 → 주민에게 도착 예상 시간 안내 (2026-10-12, 시각장애인 음성 안내 B12)

방재단원이 대상을 맡으면(PATCH /admin/incidents/{id}/targets/{tid} assigned_to=me):
  1. 방재단원 위치(user_devices.last_location, 최근 30분) → 대상 위치로 도착 예상 시간을 계산
     route 서비스(POST /api/route, 도보 최단) → 실패하면 직선거리 × 1.3 ÷ 1.2 m/s
  2. incident_targets.assigned_at · assignee_eta_s 에 남김 (주민 폴링 GET /alerts 의 evacuation.eta_min)
  3. 주민 앱(앱 사용자 본인 또는 가구에 연결된 앱 사용자)에 FCM kind=responder_assigned (eta_min, tts_text)
     → 앱이 시각장애인이면 gpt-realtime 으로 tts_text 를 읽는다 (app/lib/services/evac_voice_check.dart)
배정 해제(null)면 두 칸을 비운다. 예외를 밖으로 내지 않는다 (배정 기록은 이미 끝난 뒤).
"""
from __future__ import annotations

import logging
import math
from typing import Optional

import httpx

from app import db
from app.config import settings
from . import fcm

log = logging.getLogger("alerts.assignment")

ROUTE_TIMEOUT_S = 3.0
WALK_MPS = 1.2                 # 직선거리 추정 걸음 속도
DETOUR = 1.3                   # 직선거리 → 실제 길 보정
LOCATION_FRESH_MIN = 30        # 이보다 오래된 방재단원 위치는 쓰지 않는다

RESPONDER_LOC_SQL = f"""
SELECT ST_Y(last_location) AS lat, ST_X(last_location) AS lng FROM user_devices
WHERE user_id = %(uid)s AND last_location IS NOT NULL AND last_location_at > now() - interval '{LOCATION_FRESH_MIN} minutes'
ORDER BY last_location_at DESC LIMIT 1
"""
SAVE_SQL = """
UPDATE care.incident_targets SET assigned_at = CASE WHEN %(assigned)s THEN now() END, assignee_eta_s = %(eta)s,
       updated_at = now()
WHERE id = %(tid)s
"""
# 받는 사람: 앱 사용자 대상이면 본인, 등록 가구 대상이면 가구에 연결된 앱 사용자
RESIDENT_TOKENS_SQL = """
SELECT DISTINCT d.fcm_token FROM care.incident_targets t
LEFT JOIN care.households h ON h.id = t.household_id
JOIN user_devices d ON d.user_id = COALESCE(t.user_id, h.linked_user_id)
WHERE t.id = %(tid)s AND d.fcm_token IS NOT NULL
"""


def straight_eta_s(a: tuple[float, float], b: tuple[float, float]) -> int:
    """(lat, lng) 두 점 직선거리로 걷는 시간 추정 (초)"""
    lat1, lng1, lat2, lng2 = map(math.radians, (*a, *b))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lng2 - lng1) / 2) ** 2
    meters = 2 * 6_371_000 * math.asin(math.sqrt(h))
    return int(round(meters * DETOUR / WALK_MPS))


def route_eta_s(a: tuple[float, float], b: tuple[float, float], http: Optional[httpx.Client] = None) -> Optional[int]:
    """route 서비스 도보 최단 경로 시간 (초). 설정이 없거나 실패하면 None"""
    if not settings.route_url:
        return None
    body = {"origin": {"lat": a[0], "lon": a[1]}, "destination": {"lat": b[0], "lon": b[1]},
            "mode": "walk", "strategy": "shortest", "profile": "adult"}
    try:
        r = (http or httpx).post(f"{settings.route_url}/api/route", json=body, timeout=ROUTE_TIMEOUT_S)
        if r.status_code == 200:
            return int(r.json()["duration_s"])
        log.info("경로 계산 실패 HTTP %s — 직선거리로 추정", r.status_code)
    except (httpx.HTTPError, KeyError, ValueError, TypeError) as e:
        log.info("경로 계산 실패 (%s) — 직선거리로 추정", type(e).__name__)
    return None


def eta_minutes(eta_s: Optional[int]) -> Optional[int]:
    return None if eta_s is None else max(1, math.ceil(eta_s / 60))


def tts_text(eta_min: Optional[int]) -> str:
    if eta_min is None:
        return "방재단원이 배정되었습니다. 곧 찾아갑니다. 안전한 곳에서 기다려 주세요."
    return f"방재단원이 배정되었습니다. 약 {eta_min}분 후 도착합니다. 안전한 곳에서 기다려 주세요."


def on_assigned(incident_id: str, target: dict, responder_id: Optional[str]) -> dict:
    """target: incidents.find_target 행 (id, lat, lng …). responder_id None = 배정 해제.
    반환: {eta_s, eta_min, push} — 시험·로그용"""
    tid = str(target["id"])
    try:
        if responder_id is None:
            db.execute(SAVE_SQL, {"assigned": False, "eta": None, "tid": tid})
            return {"eta_s": None, "eta_min": None, "push": None}
        eta_s = None
        loc = db.fetch_one(RESPONDER_LOC_SQL, {"uid": responder_id})
        if loc and target.get("lat") is not None:
            a, b = (loc["lat"], loc["lng"]), (target["lat"], target["lng"])
            eta_s = route_eta_s(a, b)
            if eta_s is None:
                eta_s = straight_eta_s(a, b)
        db.execute(SAVE_SQL, {"assigned": True, "eta": eta_s, "tid": tid})
        eta_min = eta_minutes(eta_s)
        text = tts_text(eta_min)
        pushes = [fcm.Push(token=r["fcm_token"], title="방재단원이 오고 있습니다",
                           body=f"약 {eta_min}분 후 도착 예정" if eta_min else "곧 찾아갑니다",
                           data=fcm.payload("responder_assigned", incident_id=incident_id, target_id=tid,
                                            eta_min=eta_min, tts_text=text, action="respond"))
                  for r in db.fetch_all(RESIDENT_TOKENS_SQL, {"tid": tid})]
        log.info("배정 안내 %s eta=%s분 → %d대", tid, eta_min, len(pushes))
        return {"eta_s": eta_s, "eta_min": eta_min, "push": fcm.send(pushes)}
    except Exception as e:  # noqa: BLE001 — 배정 자체는 이미 기록됨
        log.warning("배정 안내 실패 %s: %s", tid, e)
        return {"eta_s": None, "eta_min": None, "push": None}
