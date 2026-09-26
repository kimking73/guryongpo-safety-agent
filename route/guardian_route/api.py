"""경로 안내 서버 HTTP 창구 (route 컨테이너).

배포 시 Caddy가 /api/route를 이 서버로 넘긴다 (B10). 앱(C5)과 AI 위치·경로 agent(B7)가 호출한다.
"""

from __future__ import annotations

import logging
from functools import lru_cache

from fastapi import Depends, FastAPI, HTTPException

from .gh import GraphHopperUnavailable, RouteNotFound
from .service import RouteRequest, RouteResponse, RouteService

logging.basicConfig(level=logging.WARNING, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("guardian_route")
log.setLevel(logging.INFO)

app = FastAPI(title="구룡가디언 경로 안내")


@lru_cache
def get_service() -> RouteService:
    """서버 전체에서 하나만 만든다 (HTTP 연결 재사용). 테스트는 dependency_overrides로 바꾼다."""
    return RouteService()


@app.get("/api/route/health")
def health(service: RouteService = Depends(get_service)) -> dict:
    # 경로 엔진이 죽어도 이 서버는 살아 있다고 답하고, 상태는 graphhopper 값으로 알린다.
    return service.health()


@app.post("/api/route", response_model=RouteResponse)
def route(req: RouteRequest, service: RouteService = Depends(get_service)) -> RouteResponse:
    try:
        return service.route(req)
    except GraphHopperUnavailable as e:
        log.warning("경로 엔진 장애: %s", e)
        raise HTTPException(503, f"경로 안내를 일시적으로 사용할 수 없습니다. {e}") from e
    except RouteNotFound as e:
        log.info("경로 없음: %s", e)
        raise HTTPException(404, f"구룡포 도로망에서 경로를 찾지 못했습니다. ({e})") from e
