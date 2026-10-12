"""대시보드 · 지도 레이어 · 긴급 전화"""
from typing import Literal, Optional, get_args

from fastapi import APIRouter, Depends, Query
from fastapi.responses import JSONResponse, Response

from .. import db, layers
from ..auth import AuthUser, current_user, optional_user
from ..errors import ApiError
from ..schemas import DemoDispatchInput, DemoEvacLocation, DemoEvacResponse, DemoEvacStart

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


# ------------------------------------------------------------------ 시연 대피 응답 (2026-10-12, app/demo_evac.py)
# 시연 모드의 대피 경보 응답을 서버에 저장 → 다른 계정의 방재단원 모드 화면이 읽고, 방재단 출동 기록은 주민 화면이 받는다.
# 실제 대피 상황·FCM 과는 분리. 주민 쪽(시작·응답·위치·내 기록)은 로그인만, 방재단 쪽(응답 목록·출동 기록)은
# 방재단·관리자 역할만 (2026-10-12 사용자 요청: 방재단 화면은 전용 코드를 받은 사람만 — 목록에 주민 위치가 들어 있다)
def _require_patrol(u: AuthUser) -> None:
    from ..auth import user_role
    role = user_role(u)
    if role not in ("responder", "admin"):
        raise ApiError("FORBIDDEN", detail={"role": role})


@router.post("/demo/evacuation/start", summary="시연 대피 경보 시작 — 내 시연 응답을 '응답 없음'으로 새로 (출동 기록도 지움)")
def post_demo_evac_start(body: DemoEvacStart, u: AuthUser = Depends(current_user)):
    from .. import demo_evac, users
    uid, _ = users.ensure_user(u)
    return demo_evac.start(uid, body.needs, body.location.model_dump() if body.location else None, u.email)


@router.post("/demo/evacuation/response", summary="시연 대피 응답 저장 (대피 완료 / 대피 중 / 도움 필요) + 이력")
def post_demo_evac_response(body: DemoEvacResponse, u: AuthUser = Depends(current_user)):
    from .. import demo_evac, users
    uid, _ = users.ensure_user(u)
    return demo_evac.respond(uid, body.status, body.needs, body.via, body.location.model_dump() if body.location else None,
                             u.email)


@router.post("/demo/evacuation/location", status_code=204, summary="시연 주민의 현재 위치 갱신 (움직일 때, 이력 없음)")
def post_demo_evac_location(body: DemoEvacLocation, u: AuthUser = Depends(current_user)):
    from .. import demo_evac, users
    uid = users.find_user_id(u)
    if not uid or not demo_evac.update_location(uid, body.location.model_dump()):
        raise ApiError("NOT_FOUND", "진행 중인 시연 대피 응답이 없습니다.", detail="demo_evac_not_found")
    return Response(status_code=204)


@router.delete("/demo/evacuation", status_code=204, summary="시연 주민 응답 전부 초기화 (앱에서 시연 모드를 다시 켤 때, 이력은 남김)")
def delete_demo_evac_all(u: AuthUser = Depends(current_user)):
    from .. import demo_evac
    demo_evac.reset()
    return Response(status_code=204)


@router.get("/demo/evacuation/me", summary="내 시연 대피 응답 + 방재단 출동 기록 (없으면 null)")
def get_demo_evac_me(u: AuthUser = Depends(current_user)):
    from .. import demo_evac, users
    uid = users.find_user_id(u)
    return demo_evac.mine(uid) if uid else None


@router.get("/demo/evacuation/responses", summary="최근 시연 대피 응답 전체 (방재단원 모드 화면용, 최근 3시간)")
def get_demo_evac_responses(u: AuthUser = Depends(current_user)):
    _require_patrol(u)
    from .. import demo_evac, users
    return demo_evac.responses(users.find_user_id(u))


@router.put("/demo/evacuation/{target_id}/dispatch", status_code=204, summary="방재단 출동 기록 쓰기 (출발·도착 예정·업무 단계)")
def put_demo_evac_dispatch(target_id: str, body: DemoDispatchInput, u: AuthUser = Depends(current_user)):
    _require_patrol(u)
    from .. import demo_evac, users
    uid, _ = users.ensure_user(u)
    demo_evac.dispatch(target_id, body.model_dump(), uid)
    return Response(status_code=204)


@router.delete("/demo/evacuation/{target_id}/dispatch", status_code=204, summary="방재단 출동 기록 지우기 (배정 해제)")
def delete_demo_evac_dispatch(target_id: str, u: AuthUser = Depends(current_user)):
    _require_patrol(u)
    from .. import demo_evac, users
    uid, _ = users.ensure_user(u)
    demo_evac.dispatch(target_id, None, uid)
    return Response(status_code=204)


@router.get("/hotlines", summary="긴급 전화 목록 (실데이터)")
def get_hotlines(hazard: Optional[Hazard] = None):
    return [{**r, "hazards": list(r["hazards"] or []), "targets": list(r["targets"] or [])}
            for r in db.fetch_all(HOTLINES_SQL, {"h": hazard})]
