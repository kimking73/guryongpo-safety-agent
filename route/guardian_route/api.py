"""경로 안내 서버 HTTP 창구 (route 컨테이너).

배포 시 Caddy가 /api/route를 이 서버로 넘긴다 (B10). 앱(C5)과 AI 위치·경로 agent(B7)가 호출한다.
"""

from __future__ import annotations

import logging
import os
from functools import lru_cache

from fastapi import Depends, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from .gh import GraphHopperUnavailable, RouteNotFound
from .sea import OutsideArea
from . import visits
from .service import (LatLon, RouteCheckRequest, RouteCheckResponse, RouteRequest, RouteResponse, RouteService,
                      SeaRouteRequest, SeaRouteResponse)

logging.basicConfig(level=logging.WARNING, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("guardian_route")
log.setLevel(logging.INFO)

app = FastAPI(title="구룡가디언 경로 안내")
# 브라우저(Flutter 웹)가 이 포트를 직접 부를 때 필요 (로컬). 배포에서는 Caddy가 같은 도메인으로 묶는다
app.add_middleware(CORSMiddleware, allow_origins=[o.strip() for o in (os.environ.get("CORS_ORIGINS") or "*").split(",") if o.strip()],
                   allow_methods=["*"], allow_headers=["*"])


@lru_cache
def get_service() -> RouteService:
    """서버 전체에서 하나만 만든다 (HTTP 연결 재사용). 테스트는 dependency_overrides로 바꾼다."""
    return RouteService()


@app.get("/api/route/health")
def health(service: RouteService = Depends(get_service)) -> dict:
    # 경로 엔진이 죽어도 이 서버는 살아 있다고 답하고, 상태는 graphhopper 값으로 알린다.
    return service.health()


@app.get("/api/route/hazards")
def hazards(demo: bool = False, service: RouteService = Depends(get_service)) -> dict:
    """경로가 피하는 위험 구역 원본 (GeoJSON). demo=true 면 시연 위험 영역. 지도에 그리려면 geojson.io 등에 붙여 넣는다."""
    return service.source(demo).raw()


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


@app.post("/api/route/check", response_model=RouteCheckResponse)
def check(req: RouteCheckRequest, service: RouteService = Depends(get_service)) -> RouteCheckResponse:
    """이동 중 위치를 받아 경로 재계산이 필요한지 알려 준다 (앱이 경로 안내 중 주기적으로 호출)."""
    try:
        return service.check(req)
    except GraphHopperUnavailable as e:
        log.warning("경로 엔진 장애: %s", e)
        raise HTTPException(503, f"경로 안내를 일시적으로 사용할 수 없습니다. {e}") from e
    except RouteNotFound as e:
        log.info("경로 없음: %s", e)
        raise HTTPException(404, f"구룡포 도로망에서 경로를 찾지 못했습니다. ({e})") from e


class SeaCheckRequest(BaseModel):
    origin: LatLon


@app.post("/api/route/sea/check")
def sea_check(req: SeaCheckRequest, service: RouteService = Depends(get_service)) -> dict:
    """지금 위치가 바다 위인지만 (경로 계산 없음, 2026-10-09). 앱 '경로 안내' 메뉴가 육상 경로 3종 ↔ 해상 경로 안내를 고른다.
    판정 = /api/route/sea와 같은 육지 지도(해안선 30m 이내는 육지). 범위 밖은 422 — 앱은 '위치 확인 필요'로 보인다."""
    try:
        return {"at_sea": service.chart.is_at_sea(req.origin.lat, req.origin.lon)}
    except OutsideArea as e:
        raise HTTPException(422, f"구룡포 일대 밖이라 바다·육지를 판별할 수 없습니다. ({e})") from e


@app.post("/api/route/sea", response_model=SeaRouteResponse)
def sea(req: SeaRouteRequest, service: RouteService = Depends(get_service)) -> SeaRouteResponse:
    """B11: 바다 위 → 최근접 항(직선 거리·방위) → 대피소(도로 경로). 출발이 육지면 at_sea=false와 일반 경로만."""
    try:
        return service.sea(req)
    except OutsideArea as e:
        raise HTTPException(422, f"구룡포 일대 밖이라 해상 경로를 안내할 수 없습니다. ({e})") from e
    except GraphHopperUnavailable as e:
        log.warning("경로 엔진 장애: %s", e)
        raise HTTPException(503, f"경로 안내를 일시적으로 사용할 수 없습니다. {e}") from e
    except RouteNotFound as e:
        log.info("경로 없음: %s", e)
        raise HTTPException(404, f"구룡포 도로망에서 경로를 찾지 못했습니다. ({e})") from e


@app.post("/api/route/visits", response_model=visits.VisitResponse)
def visit_route(req: visits.VisitRequest, service: RouteService = Depends(get_service)) -> visits.VisitResponse:
    """방재단 다중 방문 경로 (2026-10-09): 출발점 → 고른 집 1~10곳. 최단 순서와 우선순위(B13 단계) 순서를 함께 준다."""
    try:
        return visits.plan(service, req)
    except GraphHopperUnavailable as e:
        log.warning("경로 엔진 장애: %s", e)
        raise HTTPException(503, f"경로 안내를 일시적으로 사용할 수 없습니다. {e}") from e
    except RouteNotFound as e:
        log.info("방문 경로 없음: %s", e)
        raise HTTPException(404, f"구룡포 도로망에서 경로를 찾지 못했습니다. ({e})") from e
