"""대피 상황 조회 (A12) — 방재단 화면(/admin/incidents*, /admin/overview) · 주민 '내 대피 확인' 카드(/alerts, /dashboard)

응답 모양은 명세 Incident · IncidentDetail · IncidentTarget · MyEvacuation (mock/admin.*.json 과 같음).
생활지원사(caregiver)는 담당 가구(households.caregiver_user_id) 대상만 본다 — caregiver 인자에 그 사용자 id.
"""
from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Optional

from . import db
from .errors import ApiError
from .mocks import iso

APP_USER_LABEL = "앱 사용자 (가구 미등록)"
STATUSES = ("no_response", "evacuating", "evacuated", "need_help")

# 대상 행 공통 필터 — caregiver 가 NULL 이면 전체
VISIBLE = ("(%(cg)s::uuid IS NULL OR t.household_id IN "
           "(SELECT id FROM care.households WHERE caregiver_user_id = %(cg)s::uuid))")

INCIDENTS_SQL = f"""
SELECT i.id, i.hazard::text AS hazard, i.level::text AS level, i.title, i.source, i.assessment_id AS area_id,
       i.started_at, i.closed_at, ST_AsGeoJSON(i.area) AS area_geojson,
       count(t.id) AS total,
       count(t.id) FILTER (WHERE t.status = 'no_response') AS no_response,
       count(t.id) FILTER (WHERE t.status = 'evacuating') AS evacuating,
       count(t.id) FILTER (WHERE t.status = 'evacuated') AS evacuated,
       count(t.id) FILTER (WHERE t.status = 'need_help') AS need_help,
       -- 방문 집계 (A14): 한 번이라도 방문한 대상 · 도움 필요인데 아직 아무도 안 간 대상
       count(t.id) FILTER (WHERE EXISTS (SELECT 1 FROM care.visit_logs v WHERE v.target_id = t.id)) AS visited,
       count(t.id) FILTER (WHERE t.status = 'need_help'
                           AND NOT EXISTS (SELECT 1 FROM care.visit_logs v WHERE v.target_id = t.id)) AS unvisited_need_help
FROM care.incidents i
LEFT JOIN care.incident_targets t ON t.incident_id = i.id AND {VISIBLE}
WHERE (%(iid)s::uuid IS NULL OR i.id = %(iid)s::uuid)
  AND (%(state)s = 'all' OR (%(state)s = 'active') = (i.closed_at IS NULL))
GROUP BY i.id
ORDER BY i.started_at DESC
"""

TARGETS_SQL = f"""
SELECT t.id, t.household_id, t.user_id, t.status::text AS status, t.status_via::text AS status_via, t.status_at,
       t.reminder_count, t.escalated_at, t.priority_score, t.priority_reasons, t.note, t.created_at, t.assigned_to,
       h.label, h.address, h.phone, h.needs, h.linked_user_id,
       ST_Y(COALESCE(h.geom, t.last_location, a.location, ST_PointOnSurface(i.area))) AS lat,
       ST_X(COALESCE(h.geom, t.last_location, a.location, ST_PointOnSurface(i.area))) AS lng,
       ST_Y(t.last_location) AS last_lat, ST_X(t.last_location) AS last_lng,
       a.created_at AS alert_at, au.nickname AS assigned_nickname,
       lv.v_id, lv.v_at, lv.v_result, lv.v_status_after, lv.v_note, lv.v_responder, lv.v_responder_nick
FROM care.incident_targets t
JOIN care.incidents i ON i.id = t.incident_id
LEFT JOIN care.households h ON h.id = t.household_id
LEFT JOIN user_alerts a ON a.id = t.alert_id
LEFT JOIN users au ON au.id = t.assigned_to
LEFT JOIN LATERAL (
  SELECT v.id AS v_id, v.visited_at AS v_at, v.result AS v_result, v.status_after::text AS v_status_after, v.note AS v_note,
         v.responder_id AS v_responder, ru.nickname AS v_responder_nick
  FROM care.visit_logs v LEFT JOIN users ru ON ru.id = v.responder_id
  WHERE v.target_id = t.id ORDER BY v.visited_at DESC LIMIT 1) lv ON true
WHERE t.incident_id = %(iid)s AND {VISIBLE}
"""


def _json(v, default):
    if v is None:
        return default
    return v if isinstance(v, (dict, list)) else json.loads(v)


def incident_out(r: dict) -> dict:
    return {"id": str(r["id"]), "hazard": r["hazard"], "level": r["level"], "title": r["title"], "source": r["source"],
            "area_id": r.get("area_id"), "started_at": iso(r["started_at"]), "closed_at": iso(r.get("closed_at")),
            "summary": {"total": r["total"], **{s: r[s] for s in STATUSES},
                        "visited": r.get("visited") or 0, "unvisited_need_help": r.get("unvisited_need_help") or 0}}


def target_out(r: dict, me: Optional[str], now: datetime) -> dict:
    hh = r.get("household_id") is not None
    since = r.get("alert_at") or r["created_at"]
    visit = None
    if r.get("v_id") is not None:
        visit = {"id": r["v_id"], "household_id": str(r["household_id"]) if hh else None, "target_id": str(r["id"]),
                 "responder": {"user_id": str(r["v_responder"]), "nickname": r.get("v_responder_nick")} if r.get("v_responder") else None,
                 "visited_at": iso(r["v_at"]), "result": r["v_result"], "status_after": r.get("v_status_after"),
                 "note": r.get("v_note")}
        if visit["responder"] is None:
            visit.pop("responder")
    assigned = None
    if r.get("assigned_to"):
        assigned = {"user_id": str(r["assigned_to"]), "nickname": r.get("assigned_nickname"),
                    "is_me": me is not None and str(r["assigned_to"]) == me}
    return {
        "id": str(r["id"]), "kind": "household" if hh else "app_user",
        "household_id": str(r["household_id"]) if hh else None,
        "label": r["label"] if hh else APP_USER_LABEL,
        "address": r.get("address") if hh else None,
        "location": {"lat": r["lat"], "lng": r["lng"]},
        "phone": r.get("phone") if hh else None,
        "needs": list(r.get("needs") or []) if hh else [],
        "has_app": (r.get("linked_user_id") is not None) if hh else True,
        "status": r["status"], "status_via": r.get("status_via"), "status_at": iso(r.get("status_at")),
        "minutes_since_alert": max(0, int((now - since).total_seconds() // 60)),
        "reminder_count": r.get("reminder_count") or 0, "escalated": r.get("escalated_at") is not None,
        "assigned_to": assigned,
        "priority_score": r.get("priority_score"), "priority_reasons": _json(r.get("priority_reasons"), []),
        "last_location": {"lat": r["last_lat"], "lng": r["last_lng"]} if r.get("last_lat") is not None else None,
        "note": r.get("note"), "last_visit": visit,
    }


# ------------------------------------------------------------------ 조회
def list_incidents(state: str = "active", caregiver: Optional[str] = None) -> list[dict]:
    return [incident_out(r) for r in db.fetch_all(INCIDENTS_SQL, {"iid": None, "state": state, "cg": caregiver})]


def get_incident(incident_id: str) -> dict:
    """요약·영역 포함 원본 행 (없으면 404)"""
    r = db.fetch_one(INCIDENTS_SQL, {"iid": incident_id, "state": "all", "cg": None})
    if not r:
        raise ApiError("NOT_FOUND")
    return r


def detail(incident_id: str, me: Optional[str], caregiver: Optional[str], rank) -> dict:
    """IncidentDetail — rank: 대상 정렬 함수 (admin.default_rank, B13 점수 우선)"""
    from alerts.evacuation import RULES
    r = db.fetch_one(INCIDENTS_SQL, {"iid": incident_id, "state": "all", "cg": caregiver})
    if not r:
        raise ApiError("NOT_FOUND")
    now = datetime.now(timezone.utc)
    targets = [target_out(t, me, now) for t in db.fetch_all(TARGETS_SQL, {"iid": incident_id, "cg": caregiver})]
    return {**incident_out(r), "area": _json(r.get("area_geojson"), None), "rules": dict(RULES),
            "targets": rank(targets), "server_time": iso(now), "next_poll_sec": 10}


def find_target(incident_id: str, target_id: str, caregiver: Optional[str]) -> dict:
    row = db.fetch_one(TARGETS_SQL + " AND t.id = %(tid)s", {"iid": incident_id, "tid": target_id, "cg": caregiver})
    if not row:
        raise ApiError("NOT_FOUND")
    return row


def overview(caregiver: Optional[str]) -> dict:
    c = {"cg": caregiver}
    hh = db.fetch_one("""SELECT count(*) AS total, count(*) FILTER (WHERE linked_user_id IS NOT NULL) AS with_app
                         FROM care.households WHERE active AND (%(cg)s::uuid IS NULL OR caregiver_user_id = %(cg)s::uuid)""", c) \
        or {"total": 0, "with_app": 0}
    needs = db.fetch_all("""SELECT n, count(*) AS c FROM care.households, unnest(needs) n
                            WHERE active AND (%(cg)s::uuid IS NULL OR caregiver_user_id = %(cg)s::uuid)
                            GROUP BY n ORDER BY n""", c)
    return {"households_total": hh["total"], "needs_counts": {r["n"]: r["c"] for r in needs},
            "with_app": hh["with_app"], "active_incidents": list_incidents("active", caregiver),
            "server_time": iso(datetime.now(timezone.utc))}


# ------------------------------------------------------------------ 주민: 내 대피 확인 카드
# 진행 중인 대피 상황에서 내 상태 — 여럿이면 높은 단계·최근 것
MY_EVAC_SQL = """
SELECT i.id AS incident_id, t.alert_id, i.hazard::text AS hazard, i.level::text AS level, i.title,
       t.status::text AS status, t.status_at, i.started_at
FROM care.incident_targets t JOIN care.incidents i ON i.id = t.incident_id
WHERE t.user_id = %(uid)s AND t.household_id IS NULL AND t.alert_id IS NOT NULL AND i.closed_at IS NULL
ORDER BY i.level DESC, i.started_at DESC LIMIT 1
"""


def my_evacuation(user_id: Optional[str]) -> Optional[dict]:
    r = db.fetch_one(MY_EVAC_SQL, {"uid": user_id}) if user_id else None
    if not r:
        return None
    return {"incident_id": str(r["incident_id"]), "alert_id": str(r["alert_id"]), "hazard": r["hazard"],
            "level": r["level"], "title": r["title"], "status": r["status"], "status_at": iso(r.get("status_at")),
            "started_at": iso(r["started_at"])}
