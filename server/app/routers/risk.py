"""위험도 — 실데이터 (A3: 침수·포항 DT 강우). 다른 재난은 A4 에서 판정 엔진에 추가"""
from typing import Literal, Optional

from fastapi import APIRouter, Query
from fastapi.responses import JSONResponse

from .. import db, layers
from risk import queries

router = APIRouter(tags=["risk"])
Hazard = Literal["landslide", "heavy_rain", "flood", "strong_wind", "typhoon", "high_seas", "fine_dust", "ultrafine_dust", "uv"]
Level = Literal["normal", "watch", "advisory", "warning", "critical"]


@router.get("/risk", summary="한 지점의 재난별 현재 위험도")
def get_risk(lat: float = Query(ge=-90, le=90), lng: float = Query(ge=-180, le=180),
             radius_m: float = Query(0, ge=0, le=5000, description="이 거리(m) 안의 위험 영역까지 포함 (0 = 그 지점이 영역 안일 때만)")):
    return queries.point_risk(lat, lng, radius_m)


@router.get("/risk/areas", summary="현재 유효한 위험 영역 GeoJSON (Feature.properties = RiskItem)")
def get_risk_areas(hazard: Optional[Hazard] = None, min_level: Optional[Level] = None,
                   bbox: Optional[str] = Query(None, description="minLng,minLat,maxLng,maxLat")):
    return JSONResponse(queries.areas(hazard, min_level, layers.parse_bbox(bbox)), media_type="application/geo+json")


@router.get("/risk/rules", summary="위험 판단 기준표 (출처 포함)")
def get_risk_rules():
    return db.fetch_all("""
        SELECT id, hazard::text AS hazard, level::text AS level, label, metric, operator, threshold, threshold_max,
               duration_min, condition, source_name, source_url
        FROM risk_rules WHERE is_active ORDER BY hazard, level, id""")
