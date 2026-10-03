"""방재단·생활지원사 — 대피 현황 · 취약 가구 · 방문 기록 (목업) — 실구현 A12(대피 상황)·A13(가구)·A14(방문), 우선순위 B13

권한: 역할 responder·caregiver·admin 만 (auth.require_staff, 아니면 403 FORBIDDEN).
dev 모드 시험: 'Authorization: Bearer dev:responder-1' (uid 앞부분이 역할), 'dev:test-uid' 는 resident → 403.
목업 데이터: server/mock/admin.*.json (2026-10-05 14:30 호우경보·환승센터 침수 시나리오)
"""
import uuid
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Query, Response

from .. import layers, mocks
from ..auth import StaffUser, require_staff
from ..errors import ApiError
from ..schemas import HouseholdInput, HouseholdPatch, IncidentInput, TargetPatch, VisitInput
from .alerts import ESCALATE_AFTER_MIN, EVACUATING_RECHECK_MIN, REMINDER_INTERVAL_MIN

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


def _incident() -> dict:
    d = mocks.load("admin.incident.json")
    d["rules"] = {"reminder_interval_min": REMINDER_INTERVAL_MIN, "escalate_after_min": ESCALATE_AFTER_MIN,
                  "evacuating_recheck_min": EVACUATING_RECHECK_MIN}
    d["targets"] = default_rank(d["targets"])
    d["server_time"] = mocks.now_iso()
    return d


def _check_incident(incident_id: uuid.UUID) -> dict:
    d = _incident()
    if str(incident_id) != d["id"]:
        raise ApiError("NOT_FOUND")
    return d


def _target(d: dict, target_id: uuid.UUID) -> dict:
    t = next((x for x in d["targets"] if x["id"] == str(target_id)), None)
    if t is None:
        raise ApiError("NOT_FOUND")
    return t


@router.get("/overview", summary="전체 요약")
def overview(staff: StaffUser = Depends(require_staff)):
    d = mocks.load("admin.overview.json")
    d.update(role=staff.role, server_time=mocks.now_iso())
    return mocks.respond(d)


@router.get("/incidents", summary="대피 상황 목록")
def list_incidents(status: Literal["active", "closed", "all"] = "active", staff: StaffUser = Depends(require_staff)):
    items = mocks.load("admin.incidents.json")
    if status == "closed":
        items = [i for i in items if i["closed_at"]]
    elif status == "active":
        items = [i for i in items if not i["closed_at"]]
    return mocks.respond(items)


@router.post("/incidents", status_code=201, summary="대피 상황 수동 시작")
def create_incident(body: IncidentInput, staff: StaffUser = Depends(require_staff)):
    d = _incident()
    d.update(id=str(uuid.uuid4()), hazard=body.hazard, level=body.level, title=body.title, source="manual",
             area_id=None, started_at=mocks.now_iso(), closed_at=None)
    return mocks.respond(d, 201)


@router.get("/incidents/{incident_id}", summary="대피 현황 (10초 폴링)")
def get_incident(incident_id: uuid.UUID, staff: StaffUser = Depends(require_staff)):
    return mocks.respond(_check_incident(incident_id))


@router.get("/incidents/{incident_id}/map", summary="대피 현황 지도")
def get_incident_map(incident_id: uuid.UUID, staff: StaffUser = Depends(require_staff)):
    _check_incident(incident_id)
    return mocks.mock("admin.incident-map.geojson")


@router.patch("/incidents/{incident_id}/targets/{target_id}", summary="대상 상태 대신 기록 · 방문 담당 지정")
def update_target(incident_id: uuid.UUID, target_id: uuid.UUID, body: TargetPatch, staff: StaffUser = Depends(require_staff)):
    d = _check_incident(incident_id)
    if d["closed_at"]:
        raise ApiError("CONFLICT")
    t = _target(d, target_id)
    data = body.model_dump(exclude_unset=True)
    if data.get("status"):
        t.update(status=data["status"], status_via="responder", status_at=mocks.now_iso())
    if "assigned_to" in data:
        if data["assigned_to"] not in (None, "me"):
            raise ApiError("VALIDATION_ERROR", detail="assigned_to 는 \"me\" 또는 null")
        t["assigned_to"] = {"user_id": str(uuid.uuid5(uuid.NAMESPACE_URL, staff.uid)), "nickname": None, "is_me": True} \
            if data["assigned_to"] == "me" else None
    if "note" in data:
        t["note"] = data["note"]
    return mocks.respond(t)


@router.post("/incidents/{incident_id}/targets/{target_id}/visits", status_code=201, summary="방문 기록")
def add_visit(incident_id: uuid.UUID, target_id: uuid.UUID, body: VisitInput, staff: StaffUser = Depends(require_staff)):
    d = _check_incident(incident_id)
    t = _target(d, target_id)
    if not t.get("household_id"):
        raise ApiError("VALIDATION_ERROR", "등록 가구에만 방문 기록을 남길 수 있습니다.", detail="not_household")
    v = mocks.load("admin.visit.json")
    v.update(household_id=t["household_id"], target_id=t["id"], visited_at=mocks.now_iso(), result=body.result,
             status_after=body.status_after or VISIT_STATUS[body.result], note=body.note,
             responder={"user_id": str(uuid.uuid5(uuid.NAMESPACE_URL, staff.uid)), "nickname": None})
    return mocks.respond(v, 201)


@router.post("/incidents/{incident_id}/close", summary="대피 상황 종료")
def close_incident(incident_id: uuid.UUID, staff: StaffUser = Depends(require_staff)):
    if staff.role == "caregiver":
        raise ApiError("FORBIDDEN", "대피 상황 종료는 방재단·관리자만 할 수 있습니다.", detail={"role": staff.role})
    d = _check_incident(incident_id)
    keys = ("id", "hazard", "level", "title", "source", "area_id", "started_at", "closed_at", "summary")
    out = {k: d[k] for k in keys}
    out["closed_at"] = mocks.now_iso()
    return mocks.respond(out)


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
