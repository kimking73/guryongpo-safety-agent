"""경고 폴링 · 대피 확인 응답 (목업) — 실구현 A5(경고)·A12(대피 응답)"""
import uuid
from datetime import datetime
from typing import Optional

from fastapi import APIRouter, Depends, Query, Response

from .. import mocks
from ..auth import AuthUser, current_user
from ..errors import ApiError
from ..schemas import EvacuationResponseInput

router = APIRouter(tags=["alerts"])

# 대피 확인 시간 규칙 (분) — 2026-10-03 팀 결정, 근거 정리 중 (프로젝트 문서 8-판단기준-근거현황 4절). 명세 IncidentDetail.rules 와 같음
REMINDER_INTERVAL_MIN = 2       # 응답 없으면 2분마다 다시 알림 (방재단에 넘길 때까지)
ESCALATE_AFTER_MIN = 10         # 응답 없으면 10분 뒤 방재단에 넘김
EVACUATING_RECHECK_MIN = 10     # '대피 중'이면 10분 뒤 다시 확인

RESPONSE_MESSAGES = {
    "evacuated": "대피 완료로 기록했어요. 대피소에서 안내를 기다려 주세요.",
    "evacuating": f"대피 중으로 기록했어요. {EVACUATING_RECHECK_MIN}분 뒤 다시 확인할게요. 도착하면 '대피 완료'를 눌러 주세요.",
    "need_help": "방재단에 도움 요청을 전달했어요. 위험하면 바로 119에 전화하세요.",
}


@router.get("/alerts", summary="새 경고 폴링 + 위치 보고")
def poll_alerts(since: Optional[datetime] = None, device_id: Optional[uuid.UUID] = None,
                lat: Optional[float] = Query(None, ge=-90, le=90), lng: Optional[float] = Query(None, ge=-180, le=180),
                u: AuthUser = Depends(current_user)):
    d = mocks.load("alerts.json")
    if since is not None:            # 두 번째 폴링부터는 새 경고 없음 → 앱의 중복 제거·since 처리 확인용
        d["alerts"] = []
    d["server_time"] = mocks.now_iso()
    return mocks.respond(d)


@router.post("/alerts/{alert_id}/read", status_code=204, summary="읽음 처리")
def read_alert(alert_id: uuid.UUID, u: AuthUser = Depends(current_user)):
    return Response(status_code=204, headers={"X-Mock": "true"})


@router.post("/alerts/{alert_id}/response", summary="대피 확인 응답 (대피 완료 / 대피 중 / 도움 필요)")
def respond_alert(alert_id: uuid.UUID, body: EvacuationResponseInput, u: AuthUser = Depends(current_user)):
    alerts = {a["id"]: a for a in mocks.load("alerts.json")["alerts"]}
    a = alerts.get(str(alert_id))
    if a is None:
        raise ApiError("NOT_FOUND")
    if not a.get("response_required"):
        raise ApiError("VALIDATION_ERROR", "대피 확인이 필요한 경고가 아닙니다.", detail="response_not_required")
    if body.status == "need_help" and body.location is None:
        raise ApiError("VALIDATION_ERROR", "도움 요청에는 현재 위치가 필요합니다.", detail="location_required")
    return mocks.respond({
        "alert_id": str(alert_id), "incident_id": a["incident_id"], "status": body.status, "recorded_at": mocks.now_iso(),
        "recheck_after_min": EVACUATING_RECHECK_MIN if body.status == "evacuating" else None,
        "message": RESPONSE_MESSAGES[body.status], "call_suggested": body.status == "need_help",
    })
