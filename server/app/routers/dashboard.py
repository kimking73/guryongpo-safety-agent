"""대시보드 · 지도 레이어 · 긴급 전화"""
from typing import Literal, Optional, get_args

from fastapi import APIRouter, Depends, Query
from fastapi.responses import JSONResponse

from .. import db, layers, mocks
from ..auth import AuthUser, current_user
from ..errors import ApiError

router = APIRouter(tags=["dashboard"])
# 위험지역 고정 영역은 산사태 취약지역만 사용 (침수·해안 영역 레이어는 두지 않음 — 침수는 실시간 판정 영역 risk_areas)
LayerId = Literal["shelters", "medical", "landslide_zones", "manholes", "stations", "risk_areas", "flood_grid"]


@router.get("/dashboard", summary="맞춤 대시보드 (목업)")
def get_dashboard(lat: float = Query(ge=-90, le=90), lng: float = Query(ge=-180, le=180),
                  scenario: Literal["normal", "emergency"] = Query("normal", description="목업 전용: 재난 모드 화면 확인"),
                  u: AuthUser = Depends(current_user)):
    return mocks.mock(f"dashboard.{scenario}.json")


@router.get("/dashboard/layers/{layer_id}", summary="지도 레이어 GeoJSON (전부 실데이터)")
def get_layer(layer_id: str, bbox: Optional[str] = Query(None, description="minLng,minLat,maxLng,maxLat")):
    if layer_id not in get_args(LayerId):
        raise ApiError("NOT_FOUND", "지도 레이어를 찾을 수 없습니다.", detail={"layer_id": layer_id, "available": list(get_args(LayerId))})
    box = layers.parse_bbox(bbox)
    if layer_id == "stations":
        return JSONResponse(layers.stations_layer(box), media_type="application/geo+json")
    if layer_id == "landslide_zones":
        return JSONResponse(layers.landslide_layer(box), media_type="application/geo+json")
    if layer_id == "risk_areas":
        from risk import queries
        return JSONResponse(queries.areas(None, None, box), media_type="application/geo+json")
    if layer_id == "flood_grid":
        return JSONResponse(layers.flood_grid_layer(box), media_type="application/geo+json")
    if layer_id == "shelters":
        return JSONResponse(layers.shelters_layer(box), media_type="application/geo+json")
    if layer_id == "medical":
        return JSONResponse(layers.medical_layer(box if bbox else layers.POHANG_BBOX), media_type="application/geo+json")
    return JSONResponse(layers.manholes_layer(box), media_type="application/geo+json")     # manholes


Hazard = Literal["landslide", "heavy_rain", "flood", "strong_wind", "typhoon", "high_seas", "fine_dust", "ultrafine_dust", "uv"]

HOTLINES_SQL = """
SELECT id, name, phone, scope, hazards::text[] AS hazards, targets, priority, note, source_name
FROM public_hotlines
WHERE %(h)s::text IS NULL OR cardinality(hazards) = 0 OR %(h)s::hazard_type = ANY (hazards)
ORDER BY priority, id
"""


@router.get("/hotlines", summary="긴급 전화 목록 (실데이터)")
def get_hotlines(hazard: Optional[Hazard] = None):
    return [{**r, "hazards": list(r["hazards"] or []), "targets": list(r["targets"] or [])}
            for r in db.fetch_all(HOTLINES_SQL, {"h": hazard})]
