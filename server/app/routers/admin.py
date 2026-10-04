"""방재단·생활지원사 — 대피 현황 (A12 실데이터) · 취약 가구 (목업, A13) · 방문 기록 (목업, A14) · 우선순위 B13

권한: 역할 responder·caregiver·admin 만 (auth.require_staff, 아니면 403 FORBIDDEN).
  caregiver 는 담당 가구(households.caregiver_user_id) 대상만 보고, 대피 상황 시작·종료는 못 한다.
dev 모드 시험: 'Authorization: Bearer dev:responder-1' (uid 앞부분이 역할), 'dev:test-uid' 는 resident → 403.
목업 데이터(가구·방문): server/mock/admin.*.json
"""
import json
import uuid
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Query, Response
from fastapi.responses import JSONResponse

from .. import db, incidents, layers, mocks, users
from ..auth import AuthUser, StaffUser, require_staff
from ..errors import ApiError
from ..schemas import HouseholdInput, HouseholdPatch, IncidentCircle, IncidentInput, TargetPatch, VisitInput

router = APIRouter(prefix="/admin", tags=["admin"])

STATUS_ORDER = {"need_help": 0, "no_response": 1, "evacuating": 2, "evacuated": 3}   # B13 점수가 없을 때 기본 순서
VISIT_STATUS = {"evacuated_with_help": "evacuated", "already_evacuated": "evacuated", "transported": "evacuated",
                "refused": "no_response", "not_home": "no_response", "other": None}


def default_rank(targets: list[dict]) -> list[dict]:
    """B13 점수가 있으면 점수 내림차순, 없으면 상태 순서 → 사정(needs) 많은 순. priority_rank 를 1부터 다시 매김"""
    def key(t):
        if t.get("priority_score") is not None:
            return (0, -t["priority_score"], 0)
        return (1, STATUS_ORDER.get(t["status"], 9), -len(t.get("needs") or []))
    out = sorted(targets, key=key)
    for i, t in enumerate(out, 1):
        t["priority_rank"] = i
    return out


def _me(staff: StaffUser) -> str:
    """방재단원 본인의 users.id (dev 토큰처럼 행이 없으면 만든다 — 담당 지정·이력 기록용)"""
    user_id, _ = users.ensure_user(AuthUser(uid=staff.uid, is_anonymous=False, dev=staff.dev))
    return user_id


def _caregiver(staff: StaffUser, me: str) -> Optional[str]:
    return me if staff.role == "caregiver" else None


def _no_caregiver(staff: StaffUser, what: str) -> None:
    if staff.role == "caregiver":
        raise ApiError("FORBIDDEN", f"{what}은(는) 방재단·관리자만 할 수 있습니다.", detail={"role": staff.role})


@router.get("/overview", summary="전체 요약")
def overview(staff: StaffUser = Depends(require_staff)):
    me = _me(staff)
    return {"role": staff.role, **incidents.overview(_caregiver(staff, me))}


@router.get("/incidents", summary="대피 상황 목록")
def list_incidents(status: Literal["active", "closed", "all"] = "active", staff: StaffUser = Depends(require_staff)):
    return incidents.list_incidents(status, _caregiver(staff, _me(staff)))


NEW_INCIDENT_SQL = """
INSERT INTO care.incidents (hazard, level, title, area, source, created_by, note)
VALUES (%(hazard)s::hazard_type, %(level)s::risk_level, %(title)s,
        CASE WHEN %(geojson)s::text IS NULL
             THEN ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326)::geography, %(r)s)::geometry)
             ELSE ST_Multi(ST_SetSRID(ST_GeomFromGeoJSON(%(geojson)s), 4326)) END,
        'manual', %(by)s, %(note)s)
RETURNING id
"""


@router.post("/incidents", status_code=201, summary="대피 상황 수동 시작")
def create_incident(body: IncidentInput, staff: StaffUser = Depends(require_staff)):
    from alerts import dispatch
    _no_caregiver(staff, "대피 상황 시작")
    me = _me(staff)
    area = body.area
    p = {"hazard": body.hazard, "level": body.level, "title": body.title, "by": me, "note": body.message,
         "geojson": None, "lat": None, "lng": None, "r": None}
    if isinstance(area, IncidentCircle):
        p.update(lat=area.center.lat, lng=area.center.lng, r=area.radius_m)
    else:
        p["geojson"] = json.dumps({"type": area.type, "coordinates": area.coordinates})
    try:
        row = db.fetch_one(NEW_INCIDENT_SQL, p)
    except Exception as e:  # noqa: BLE001 — 잘못된 GeoJSON 좌표
        if p["geojson"] is None:
            raise
        raise ApiError("VALIDATION_ERROR", "영역(area) 도형이 올바르지 않습니다.", detail=type(e).__name__)
    iid = str(row["id"])
    dispatch.start_manual(iid, body.hazard, body.level, body.title, body.message)
    return JSONResponse(incidents.detail(iid, me, None, default_rank), status_code=201)


@router.get("/incidents/{incident_id}", summary="대피 현황 (10초 폴링)")
def get_incident(incident_id: uuid.UUID, staff: StaffUser = Depends(require_staff)):
    me = _me(staff)
    return incidents.detail(str(incident_id), me, _caregiver(staff, me), default_rank)


@router.get("/incidents/{incident_id}/map", summary="대피 현황 지도")
def get_incident_map(incident_id: uuid.UUID, staff: StaffUser = Depends(require_staff)):
    me = _me(staff)
    d = incidents.detail(str(incident_id), me, _caregiver(staff, me), default_rank)
    feats = [{"type": "Feature", "geometry": d["area"],
              "properties": {"kind": "area", "incident_id": d["id"], "hazard": d["hazard"], "level": d["level"]}}]
    feats += [{"type": "Feature", "geometry": {"type": "Point", "coordinates": [t["location"]["lng"], t["location"]["lat"]]},
               "properties": {"kind": "target", "target_id": t["id"], "label": t["label"], "status": t["status"],
                              "priority_rank": t["priority_rank"], "needs": t["needs"],
                              "assigned_to_me": bool(t["assigned_to"] and t["assigned_to"]["is_me"])}}
              for t in d["targets"]]
    return JSONResponse({"type": "FeatureCollection", "features": feats}, media_type="application/geo+json")


def _open_incident(incident_id: str) -> dict:
    r = incidents.get_incident(incident_id)
    if r.get("closed_at") is not None:
        raise ApiError("CONFLICT", "이미 종료된 대피 상황입니다.", detail="incident_closed")
    return r


@router.patch("/incidents/{incident_id}/targets/{target_id}", summary="대상 상태 대신 기록 · 방문 담당 지정")
def update_target(incident_id: uuid.UUID, target_id: uuid.UUID, body: TargetPatch, staff: StaffUser = Depends(require_staff)):
    from alerts import evacuation
    iid, tid = str(incident_id), str(target_id)
    me = _me(staff)
    _open_incident(iid)
    t = incidents.find_target(iid, tid, _caregiver(staff, me))
    data = body.model_dump(exclude_unset=True)
    if "assigned_to" in data and data["assigned_to"] not in (None, "me"):
        raise ApiError("VALIDATION_ERROR", detail="assigned_to 는 \"me\" 또는 null")
    if data.get("status"):
        evacuation.record({"id": tid, "incident_id": iid, "user_id": t.get("user_id")}, data["status"], "responder",
                          by_user_id=me, note=data.get("note"))
    if "assigned_to" in data:
        db.execute("UPDATE care.incident_targets SET assigned_to = %(a)s, updated_at = now() WHERE id = %(tid)s",
                   {"a": me if data["assigned_to"] == "me" else None, "tid": tid})
    if "note" in data and not data.get("status"):
        db.execute("UPDATE care.incident_targets SET note = %(n)s, updated_at = now() WHERE id = %(tid)s",
                   {"n": data["note"], "tid": tid})
    d = incidents.detail(iid, me, _caregiver(staff, me), default_rank)
    return next(x for x in d["targets"] if x["id"] == tid)


@router.post("/incidents/{incident_id}/targets/{target_id}/visits", status_code=201, summary="방문 기록 (목업, A14)")
def add_visit(incident_id: uuid.UUID, target_id: uuid.UUID, body: VisitInput, staff: StaffUser = Depends(require_staff)):
    me = _me(staff)
    t = incidents.find_target(str(incident_id), str(target_id), _caregiver(staff, me))
    if not t.get("household_id"):
        raise ApiError("VALIDATION_ERROR", "등록 가구에만 방문 기록을 남길 수 있습니다.", detail="not_household")
    v = mocks.load("admin.visit.json")
    v.update(household_id=str(t["household_id"]), target_id=str(target_id), visited_at=mocks.now_iso(), result=body.result,
             status_after=body.status_after or VISIT_STATUS[body.result], note=body.note,
             responder={"user_id": me, "nickname": None})
    return mocks.respond(v, 201)


@router.post("/incidents/{incident_id}/close", summary="대피 상황 종료")
def close_incident(incident_id: uuid.UUID, staff: StaffUser = Depends(require_staff)):
    from alerts import dispatch
    _no_caregiver(staff, "대피 상황 종료")
    iid = str(incident_id)
    r = _open_incident(iid)
    db.execute("UPDATE care.incidents SET closed_at = now() WHERE id = %(iid)s AND closed_at IS NULL", {"iid": iid})
    dispatch.push_closed([{"id": iid, "title": r["title"]}])
    return incidents.incident_out(incidents.get_incident(iid))


# ------------------------------------------------------------------ 취약 가구
@router.get("/households", summary="취약 가구 목록")
def list_households(q: Optional[str] = None, needs: Optional[str] = None, bbox: Optional[str] = Query(None),
                    staff: StaffUser = Depends(require_staff)):
    items = mocks.load("admin.households.json")
    if q:
        items = [h for h in items if q in h["label"] or q in (h.get("address") or "")]
    if needs:
        want = {x.strip() for x in needs.split(",") if x.strip()}
        items = [h for h in items if want <= set(h["needs"])]
    if bbox:
        a, b, c, e = layers.parse_bbox(bbox)
        items = [h for h in items if a <= h["location"]["lng"] <= c and b <= h["location"]["lat"] <= e]
    return mocks.respond(items)


@router.post("/households", status_code=201, summary="취약 가구 대리 등록")
def create_household(body: HouseholdInput, staff: StaffUser = Depends(require_staff)):
    data = body.model_dump()
    source = "caregiver" if staff.role == "caregiver" else "responder"
    h = {"id": str(uuid.uuid4()), "label": data["label"], "address": data["address"], "location": data["location"],
         "phone": data["phone"], "members": data["members"], "needs": data["needs"], "has_app": False,
         "caregiver": None, "source": source,
         "consent": {"at": mocks.now_iso(), "method": data["consent_method"], "by": data["consent_by"]},
         "landslide_zone": None, "note": data["note"], "updated_at": mocks.now_iso()}
    return mocks.respond(h, 201)


def _household(household_id: uuid.UUID) -> dict:
    h = next((x for x in mocks.load("admin.households.json") if x["id"] == str(household_id)), None)
    if h is None:
        raise ApiError("NOT_FOUND")
    return h


@router.get("/households/{household_id}", summary="가구 상세 + 최근 방문 기록")
def get_household(household_id: uuid.UUID, staff: StaffUser = Depends(require_staff)):
    h = _household(household_id)
    v = mocks.load("admin.visit.json")
    h["recent_visits"] = [v] if v["household_id"] == h["id"] else []
    return mocks.respond(h)


@router.patch("/households/{household_id}", summary="가구 정보 수정")
def update_household(household_id: uuid.UUID, body: HouseholdPatch, staff: StaffUser = Depends(require_staff)):
    h = _household(household_id)
    data = body.model_dump(exclude_unset=True)
    data.pop("caregiver_user_id", None)
    data.pop("active", None)
    h.update(data)
    h["updated_at"] = mocks.now_iso()
    return mocks.respond(h)


@router.delete("/households/{household_id}", status_code=204, summary="가구 삭제")
def delete_household(household_id: uuid.UUID, staff: StaffUser = Depends(require_staff)):
    return Response(status_code=204, headers={"X-Mock": "true"})
