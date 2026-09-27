"""GET /health — 서버·DB·수집기 상태 (인증 없음, 실데이터)"""
from fastapi import APIRouter
from fastapi.responses import JSONResponse

from .. import health

router = APIRouter(tags=["system"])


@router.get("/health", summary="서버·DB·수집기 상태")
def get_health():
    h = health.compute()
    # 로드밸런서·Uptime check 용: DB 가 죽었을 때만 503 (수집 지연은 200 + degraded)
    return JSONResponse(h, status_code=503 if h["status"] == "down" else 200)
