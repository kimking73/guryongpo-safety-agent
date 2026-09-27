"""대시보드 · 지도 레이어"""
from typing import Literal, Optional, get_args

from fastapi import APIRouter, Depends, Query
from fastapi.responses import JSONResponse

from .. import layers, mocks
from ..auth import AuthUser, current_user
from ..errors import ApiError

router = APIRouter(tags=["dashboard"])
LayerId = Literal["shelters", "medical", "landslide_zones", "flood_zones", "coastal_zones", "manholes", "stations", "risk_areas"]
MOCK_LAYERS = {"shelters": "layer.shelters.geojson"}


@router.get("/dashboard", summary="맞춤 대시보드 (목업)")
def get_dashboard(lat: float = Query(ge=-90, le=90), lng: float = Query(ge=-180, le=180),
                  scenario: Literal["normal", "emergency"] = Query("normal", description="목업 전용: 재난 모드 화면 확인"),
                  u: AuthUser = Depends(current_user)):
    return mocks.mock(f"dashboard.{scenario}.json")


@router.get("/dashboard/layers/{layer_id}", summary="지도 레이어 GeoJSON (stations·landslide_zones·risk_areas 는 실데이터)")
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
    if layer_id in MOCK_LAYERS:
        return mocks.mock(MOCK_LAYERS[layer_id])
    # 아직 데이터 없음 (medical·flood_zones·coastal_zones·manholes) → 빈 레이어
    return mocks.respond({"type": "FeatureCollection", "features": []}, media_type="application/geo+json")
