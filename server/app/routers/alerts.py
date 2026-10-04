"""경고 폴링 · 읽음 (A5 실데이터) · 대피 확인 응답 (목업 — 실구현 A12)"""
import json
import logging
import uuid
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, Depends, Query, Response

from .. import db, mocks, users
from ..auth import AuthUser, current_user
from ..errors import ApiError
from ..schemas import EvacuationResponseInput

router = APIRouter(tags=["alerts"])
log = logging.getLogger(__name__)

# 대피 확인 시간 규칙 (분) — 2026-10-03 팀 결정, 근거 정리 중 (프로젝트 문서 8-판단기준-근거현황 4절). 명세 IncidentDetail.rules 와 같음
REMINDER_INTERVAL_MIN = 2       # 응답 없으면 2분마다 다시 알림 (방재단에 넘길 때까지)
ESCALATE_AFTER_MIN = 10         # 응답 없으면 10분 뒤 방재단에 넘김
EVACUATING_RECHECK_MIN = 10     # '대피 중'이면 10분 뒤 다시 확인

RESPONSE_MESSAGES = {
    "evacuated": "대피 완료로 기록했어요. 대피소에서 안내를 기다려 주세요.",
    "evacuating": f"대피 중으로 기록했어요. {EVACUATING_RECHECK_MIN}분 뒤 다시 확인할게요. 도착하면 '대피 완료'를 눌러 주세요.",
    "need_help": "방재단에 도움 요청을 전달했어요. 위험하면 바로 119에 전화하세요.",
}


POLL_NORMAL_SEC, POLL_EMERGENCY_SEC = 60, 15
DEFAULT_LOOKBACK = timedelta(hours=24)     # since 없이 첫 호출 → 최근 24시간
MAX_ALERTS = 50

# since 이후 생성됐거나 내 대피 상태가 바뀐 경고 (오래된 것부터 — 목업과 같은 순서)
POLL_SQL = """
SELECT * FROM (
  SELECT a.id, a.hazard::text AS hazard, a.level::text AS level, a.title, a.body, a.reason, a.actions, a.created_at,
         a.read_at, a.response_required, a.incident_id, a.tts_text, ST_Y(a.location) AS lat, ST_X(a.location) AS lng,
         ra.id AS ra_id, ra.label AS ra_label, ra.rule_id, ra.basis, t.status::text AS my_status
  FROM user_alerts a
  LEFT JOIN risk_assessments ra ON ra.id = a.assessment_id
  LEFT JOIN care.incident_targets t ON t.incident_id = a.incident_id AND t.user_id = a.user_id AND t.household_id IS NULL
  WHERE a.user_id = %(uid)s AND (a.created_at > %(since)s OR t.status_at > %(since)s)
  ORDER BY a.created_at DESC LIMIT %(n)s
) x ORDER BY created_at
"""
# 진행 중인 대피 상황에서 내 상태 (대시보드 상단 카드) — 여럿이면 높은 단계·최근 것
EVAC_SQL = """
SELECT i.id AS incident_id, t.alert_id, i.hazard::text AS hazard, i.level::text AS level, i.title,
       t.status::text AS status, t.status_at, i.started_at
FROM care.incident_targets t JOIN care.incidents i ON i.id = t.incident_id
WHERE t.user_id = %(uid)s AND t.household_id IS NULL AND t.alert_id IS NOT NULL AND i.closed_at IS NULL
ORDER BY i.level DESC, i.started_at DESC LIMIT 1
"""


def _json(v, default):
    if v is None:
        return default
    return v if isinstance(v, (dict, list)) else json.loads(v)


def alert_out(r: dict) -> dict:
    from risk.levels import HAZARD_KO, LEVEL_NUM
    from risk.queries import risk_item
    from alerts.messages import LEVEL_KO
    if r.get("ra_id") is not None:
        risk = risk_item({"id": r["ra_id"], "hazard": r["hazard"], "level": r["level"], "label": r["ra_label"],
                          "rule_id": r["rule_id"], "basis": r["basis"]})
        risk["hazard"], risk["level"], risk["level_num"] = r["hazard"], r["level"], LEVEL_NUM[r["level"]]
    else:                                   # 재난문자 대피 안내 (판정 없음)
        risk = {"hazard": r["hazard"], "level": r["level"], "level_num": LEVEL_NUM[r["level"]],
                "label": f"{HAZARD_KO.get(r['hazard'], r['hazard'])} {LEVEL_KO.get(r['level'], r['level'])}",
                "reason": "긴급재난문자 대피 안내", "area_id": None, "rule_id": None, "observed_at": None}
        if r.get("lat") is not None:
            risk["location"] = {"lat": r["lat"], "lng": r["lng"]}
    status = r.get("my_status")
    return {
        "id": str(r["id"]), "risk": risk, "title": r["title"], "body": r["body"],
        "reason": _json(r.get("reason"), {}), "actions": _json(r.get("actions"), []),
        "created_at": mocks.iso(r["created_at"]), "read_at": mocks.iso(r.get("read_at")),
        "response_required": bool(r.get("response_required")),
        "incident_id": str(r["incident_id"]) if r.get("incident_id") else None,
        "my_status": status if status and status != "no_response" else None,
        "tts_text": r.get("tts_text"),
    }


def evacuation_out(r: Optional[dict]) -> Optional[dict]:
    if not r:
        return None
    return {"incident_id": str(r["incident_id"]), "alert_id": str(r["alert_id"]), "hazard": r["hazard"],
            "level": r["level"], "title": r["title"], "status": r["status"], "status_at": mocks.iso(r.get("status_at")),
            "started_at": mocks.iso(r["started_at"])}


@router.get("/alerts", summary="새 경고 폴링 + 위치 보고")
def poll_alerts(since: Optional[datetime] = None, device_id: Optional[uuid.UUID] = None,
                lat: Optional[float] = Query(None, ge=-90, le=90), lng: Optional[float] = Query(None, ge=-180, le=180),
                u: AuthUser = Depends(current_user)):
    server_time = datetime.now(timezone.utc)
    user_id, _ = users.ensure_user(u)
    if lat is not None and lng is not None:
        users.report_location(user_id, str(device_id) if device_id else None, lat, lng)
        try:                                 # 보낸 위치로 즉시 판정 — 실패해도 폴링은 응답 (다음 주기 실행이 다시 확인)
            from alerts import dispatch
            dispatch.run(user_id=user_id)
        except Exception:  # noqa: BLE001
            log.exception("폴링 즉시 경고 판정 실패 user=%s", user_id)
    if since is not None and since.tzinfo is None:
        since = since.replace(tzinfo=mocks.KST)
    rows = db.fetch_all(POLL_SQL, {"uid": user_id, "since": since or server_time - DEFAULT_LOOKBACK, "n": MAX_ALERTS})
    evac = evacuation_out(db.fetch_one(EVAC_SQL, {"uid": user_id}))
    weather_bulletins = mocks.load("alerts.json").get("weather_bulletins", [])
    return {"alerts": [alert_out(r) for r in rows], "weather_bulletins": weather_bulletins,
            "mode": "emergency" if evac else "normal", "evacuation": evac,
            "server_time": mocks.iso(server_time), "next_poll_sec": POLL_EMERGENCY_SEC if evac else POLL_NORMAL_SEC}


@router.post("/alerts/{alert_id}/read", status_code=204, summary="읽음 처리")
def read_alert(alert_id: uuid.UUID, u: AuthUser = Depends(current_user)):
    n = db.execute("""UPDATE user_alerts SET read_at = COALESCE(read_at, now())
                      WHERE id = %(aid)s AND user_id = (SELECT id FROM users WHERE firebase_uid = %(uid)s)""",
                   {"aid": str(alert_id), "uid": u.uid})
    if not n:
        raise ApiError("NOT_FOUND")
    return Response(status_code=204)


@router.post("/alerts/{alert_id}/response", summary="대피 확인 응답 (대피 완료 / 대피 중 / 도움 필요)")
def respond_alert(alert_id: uuid.UUID, body: EvacuationResponseInput, u: AuthUser = Depends(current_user)):
    # 경고 확인은 실데이터, 상태 저장·재알림·이관은 A12 에서 (응답은 X-Mock: true)
    a = db.fetch_one("""SELECT response_required, incident_id FROM user_alerts
                        WHERE id = %(aid)s AND user_id = (SELECT id FROM users WHERE firebase_uid = %(uid)s)""",
                     {"aid": str(alert_id), "uid": u.uid})
    if a is None:
        raise ApiError("NOT_FOUND")
    if not a.get("response_required"):
        raise ApiError("VALIDATION_ERROR", "대피 확인이 필요한 경고가 아닙니다.", detail="response_not_required")
    if body.status == "need_help" and body.location is None:
        raise ApiError("VALIDATION_ERROR", "도움 요청에는 현재 위치가 필요합니다.", detail="location_required")
    return mocks.respond({
        "alert_id": str(alert_id), "incident_id": str(a["incident_id"]), "status": body.status, "recorded_at": mocks.now_iso(),
        "recheck_after_min": EVACUATING_RECHECK_MIN if body.status == "evacuating" else None,
        "message": RESPONSE_MESSAGES[body.status], "call_suggested": body.status == "need_help",
    })
