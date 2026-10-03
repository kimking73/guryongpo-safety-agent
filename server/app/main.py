"""구룡가디언 API 서버 (FastAPI)

실행 (server/ 에서)
  uvicorn app.main:app --reload                   # 로컬
  AUTH_MODE=dev uvicorn app.main:app --reload     # Firebase 없이 'Bearer dev:<uid>' 로 호출
문서: http://localhost:8000/api/v1/docs  (배포 시 Caddy 가 /api/* 만 FastAPI 로 넘기므로 /api 아래에 둠)
명세 원본: server/spec/openapi.yaml (api·ai·route 3개 서비스 규약, tests/test_spec.py 가 코드·목업과 대조)
AI 대화·음성은 ai 서비스(/api/chat), 경로는 route 서비스(/api/route) — 이 서버에는 없음 (v0.3)
"""
from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from . import auth, db, errors
from .config import settings
from .routers import admin, alerts, dashboard, internal, risk, system, user

log = logging.getLogger("app")
API_PREFIX = "/api/v1"


@asynccontextmanager
async def lifespan(app: FastAPI):
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    # httpx 는 요청 URL 전체(인증키 포함)를 INFO 로 남김 → 키 노출 방지
    logging.getLogger("httpx").setLevel(logging.WARNING)
    db.init_pool(settings.database_url)
    if settings.auth_mode == "dev":
        log.warning("AUTH_MODE=dev — 'Bearer dev:<uid>' 허용. 배포 서버에서는 사용 금지")
    else:
        auth.init_firebase()
    if settings.enable_scheduler:
        from collector.scheduler import start_background
        start_background()
    yield
    if settings.enable_scheduler:
        from collector.scheduler import stop_background
        stop_background()
    db.close_pool()


def create_app() -> FastAPI:
    app = FastAPI(title="구룡가디언 API", version=settings.version, lifespan=lifespan,
                  docs_url=f"{API_PREFIX}/docs", redoc_url=None, openapi_url=f"{API_PREFIX}/openapi.json",
                  description="구룡포 재난 지킴이 서버. 목업 응답에는 X-Mock: true 헤더가 붙는다.")
    app.add_middleware(CORSMiddleware, allow_origins=settings.cors_origins, allow_methods=["*"],
                       allow_headers=["*"], expose_headers=["X-Mock"])
    errors.install(app)
    for r in (system, user, dashboard, risk, alerts, admin, internal):
        app.include_router(r.router, prefix=API_PREFIX)
    # 배포 헬스체크 경로 (B10: https://도메인/api/health) — /api/v1/health 와 같은 응답
    app.add_api_route("/api/health", system.get_health, methods=["GET"], include_in_schema=False)
    return app


app = create_app()
