"""경고 폴링 (목업) — 실구현 A5"""
import uuid
from datetime import datetime
from typing import Optional

from fastapi import APIRouter, Depends, Query, Response

from .. import mocks
from ..auth import AuthUser, current_user

router = APIRouter(tags=["alerts"])


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
