"""대시보드 · 지도 레이어 · 긴급 전화"""
from typing import Literal, Optional, get_args

from fastapi import APIRouter, Depends, Query
from fastapi.responses import JSONResponse

from .. import db, layers
from ..auth import AuthUser, current_user, optional_user
from ..errors import ApiError

router = APIRouter(tags=["dashboard"])
# 위험지역 고정 영역은 산사태 취약지역만 사용 (침수·해안 영역 레이어는 두지 않음 — 침수는 실시간 판정 영역 risk_areas)
LayerId = Literal["shelters", "medical", "landslide_zones", "manholes", "stations", "risk_areas", "flood_grid"]


@router.get("/dashboard", summary="맞춤 대시보드 (실데이터 — app/widgets.py). 로그인 없이도 — 그때는 등록 장소·내 대피 카드만 빠진다")
def get_dashboard(lat: float = Query(ge=-90, le=90), lng: float = Query(ge=-180, le=180),
                  u: Optional[AuthUser] = Depends(optional_user)):
    # 2026-10-08: 앱이 로그인하지 않은 사람에게 익명 계정을 만들지 않게 되어(사용자 결정), 첫 화면은 로그인 없이 열린다
    from .. import incidents, users, widgets
    user_id = users.find_user_id(u) if u else None
    # 내 대피 확인 카드 (A12) — 진행 중인 대피 상황이 있으면 실제 상태, 없으면 null
    return widgets.build(lat, lng, user_id, incidents.my_evacuation(user_id))


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


SUPPORT_SQL = """
SELECT id, category, hazards::text[] AS hazards, targets, name, summary, eligibility, how_to_apply, apply_period,
       department, contact, url, updated_at
FROM support_programs
WHERE %(h)s::text IS NULL OR cardinality(hazards) = 0 OR %(h)s::hazard_type = ANY (hazards)
ORDER BY category, id
"""


@router.get("/support-programs", summary="재난 복구·지원 제도 (실데이터, support_programs)")
def get_support_programs(hazard: Optional[Hazard] = None):
    from ..mocks import iso
    return [{**r, "hazards": list(r["hazards"] or []), "targets": list(r["targets"] or []), "updated_at": iso(r["updated_at"])}
            for r in db.fetch_all(SUPPORT_SQL, {"h": hazard})]


DemoLevel = Literal["normal", "watch", "advisory", "warning", "critical"]


@router.get("/demo/dashboard", summary="시연 모드 대시보드 (실제 센서 위치 + 시연 측정값, 실측과 같은 판정 규칙, 저장 안 함)")
def get_demo_dashboard(lat: float = Query(ge=-90, le=90), lng: float = Query(ge=-180, le=180),
                       u: Optional[AuthUser] = Depends(optional_user)):
    from risk import demo
    from .. import users
    return demo.dashboard(lat, lng, users.find_user_id(u) if u else None)


@router.get("/demo/risk/areas", summary="시연 위험 영역 (/risk/areas 와 같은 모양 — 경로 서버 demo=true 가 피한다)")
def get_demo_risk_areas(hazard: Optional[Hazard] = None, min_level: Optional[DemoLevel] = None,
                        bbox: Optional[str] = Query(None)):
    from risk import demo
    return JSONResponse(demo.risk_areas(hazard, min_level, layers.parse_bbox(bbox)), media_type="application/geo+json")


@router.get("/demo/layers/{layer_id}", summary="시연 지도 레이어 (flood_grid · stations)")
def get_demo_layer(layer_id: Literal["flood_grid", "stations"], bbox: Optional[str] = Query(None)):
    from risk import demo
    box = layers.parse_bbox(bbox)
    fc = demo.flood_grid(box) if layer_id == "flood_grid" else demo.stations_layer(box)
    return JSONResponse(fc, media_type="application/geo+json")


@router.get("/demo/households", summary="시연용 가상 취약 가구 (앱 시연 모드 방재단 화면, 실제 개인정보 아님)")
def get_demo_households():
    from .. import households
    return households.list_demo()


@router.get("/hotlines", summary="긴급 전화 목록 (실데이터)")
def get_hotlines(hazard: Optional[Hazard] = None):
    return [{**r, "hazards": list(r["hazards"] or []), "targets": list(r["targets"] or [])}
            for r in db.fetch_all(HOTLINES_SQL, {"h": hazard})]
