"""취약 가구 (A13) — 본인 등록(/user/household) · 대리 등록·관리(/admin/households*) · 민감정보 동의

- 등록에는 동의가 꼭 있어야 한다: 본인은 앱 동의(consent=true), 대리 등록은 서면·구두 동의 확인(consent_method·consent_by).
  동의 일시·방법·동의자·동의서 버전(CONSENT_VERSION)을 함께 저장 (개인정보 보호법 제23조 민감정보 별도 동의)
- 동의 철회 = 가구 삭제 (그 가구의 대피 대상·방문 기록도 ON DELETE CASCADE 로 삭제)
- 생활지원사(caregiver)는 담당 가구만 보고 고친다. 일반 계정(resident)은 본인 가구만 (/user/household)
- 응답 모양은 명세 Household (mock/household.json · admin.households.json 과 같음)
"""
from __future__ import annotations

from typing import Optional

from . import db
from .errors import ApiError
from .mocks import iso

# 동의 문구가 바뀌면 올린다 (앱 동의 화면·서면 동의서와 같은 버전). 이전 버전으로 동의한 가구는 consent.version 으로 구분
CONSENT_VERSION = "v1"
DEMO_PREFIX = "[시연] "             # /internal/simulate demo_households 가 만든 가상 가구 (실제 개인정보 아님)

# landslide: 산사태위험지도 1등급 비탈 100m 안이면 그 거리, 아니면 지정 취약지역 이름, 아니면 1·2등급 100m 범위 여부
#   (대피소 레이어 layers.SHELTERS_SQL 과 같은 방식 — 100m 범위로 먼저 거른 뒤에만 거리 계산)
HOUSEHOLD_SQL = """
SELECT h.id, h.label, h.address, ST_Y(h.geom) AS lat, ST_X(h.geom) AS lng, h.phone, h.members, h.needs,
       h.linked_user_id, h.caregiver_user_id, cu.nickname AS caregiver_nickname, h.source,
       h.consent_at, h.consent_method, h.consent_by, h.consent_version, h.note, h.active, h.updated_at,
       (SELECT round(ST_Distance(h.geom::geography, g1.geom::geography))
        FROM hazard_zones b JOIN hazard_zones g1 ON g1.hazard = 'landslide' AND g1.external_id = 'riskmap_g1'
        WHERE b.hazard = 'landslide' AND b.external_id = 'riskmap_g1_buf100' AND ST_Intersects(b.geom, h.geom)) AS landslide_g1_m,
       (SELECT z.name FROM hazard_zones z
        WHERE z.hazard = 'landslide' AND COALESCE(z.meta->>'role', '') NOT IN ('trigger_area', 'display')
          AND ST_Intersects(z.geom, h.geom) LIMIT 1) AS landslide_designated,
       EXISTS (SELECT 1 FROM hazard_zones z WHERE z.hazard = 'landslide' AND z.external_id = 'riskmap_g12_buf100'
               AND ST_Intersects(z.geom, h.geom)) AS landslide_g12
FROM care.households h
LEFT JOIN users cu ON cu.id = h.caregiver_user_id
WHERE {where}
ORDER BY h.label, h.id
"""
# caregiver 가 NULL 이면 전체, 아니면 담당 가구만
VISIBLE = "(%(cg)s::uuid IS NULL OR h.caregiver_user_id = %(cg)s::uuid)"


def landslide_label(r: dict) -> Optional[str]:
    if r.get("landslide_g1_m") is not None:
        return f"산사태위험지도 1등급 비탈 {int(r['landslide_g1_m'])}m"
    if r.get("landslide_designated"):
        return f"산사태 취약지역 ({r['landslide_designated']})"
    if r.get("landslide_g12"):
        return "산사태위험지도 1·2등급 비탈 100m 이내"
    return None


def household_out(r: dict) -> dict:
    return {
        "id": str(r["id"]), "label": r["label"], "address": r.get("address"),
        "location": {"lat": r["lat"], "lng": r["lng"]}, "phone": r.get("phone"), "members": r["members"],
        "needs": list(r.get("needs") or []), "has_app": r.get("linked_user_id") is not None,
        "caregiver": {"user_id": str(r["caregiver_user_id"]), "nickname": r.get("caregiver_nickname")}
        if r.get("caregiver_user_id") else None,
        "source": r["source"],
        "consent": {"at": iso(r["consent_at"]), "method": r["consent_method"], "by": r["consent_by"],
                    "version": r.get("consent_version") or CONSENT_VERSION},
        "landslide_zone": landslide_label(r), "note": r.get("note"), "active": bool(r.get("active", True)),
        "updated_at": iso(r.get("updated_at")),
    }


# ------------------------------------------------------------------ 조회
def list_households(caregiver: Optional[str], q: Optional[str] = None, needs: Optional[list[str]] = None,
                    bbox: Optional[tuple] = None, include_inactive: bool = False) -> list[dict]:
    where = [VISIBLE]
    p: dict = {"cg": caregiver}
    if not include_inactive:
        where.append("h.active")
    if q:
        where.append("(h.label ILIKE %(q)s OR h.address ILIKE %(q)s)")
        p["q"] = f"%{q}%"
    if needs:
        where.append("h.needs @> %(needs)s::text[]")
        p["needs"] = needs
    if bbox:
        where.append("ST_Intersects(h.geom, ST_MakeEnvelope(%(a)s, %(b)s, %(c)s, %(d)s, 4326))")
        p.update(dict(zip("abcd", bbox)))
    return [household_out(r) for r in db.fetch_all(HOUSEHOLD_SQL.format(where=" AND ".join(where)), p)]


def list_demo() -> list[dict]:
    """시연용 가상 가구만 (표시명이 DEMO_PREFIX 로 시작, /internal/simulate demo_households) — 앱 시연 모드의 방재단 화면용.
    실제 개인정보가 아니라서 방재단 역할 없이도 본다 (2026-10-05)"""
    return [household_out(r) for r in db.fetch_all(
        HOUSEHOLD_SQL.format(where="h.active AND h.label LIKE %(p)s"), {"p": DEMO_PREFIX + "%"})]


def get(household_id: str, caregiver: Optional[str] = None) -> dict:
    r = db.fetch_one(HOUSEHOLD_SQL.format(where=f"h.id = %(hid)s AND {VISIBLE}"), {"hid": household_id, "cg": caregiver})
    if not r:
        raise ApiError("NOT_FOUND")            # 남의 담당 가구도 404 (있는지 여부도 알리지 않음)
    return household_out(r)


def get_mine(user_id: str) -> Optional[dict]:
    r = db.fetch_one(HOUSEHOLD_SQL.format(where="h.linked_user_id = %(uid)s"), {"uid": user_id})
    return household_out(r) if r else None


RECENT_VISITS_SQL = """
SELECT v.id, v.household_id, v.target_id, v.visited_at, v.result, v.status_after::text AS status_after, v.note,
       v.responder_id, u.nickname AS responder_nickname
FROM care.visit_logs v LEFT JOIN users u ON u.id = v.responder_id
WHERE v.household_id = %(hid)s ORDER BY v.visited_at DESC LIMIT 5
"""


def recent_visits(household_id: str) -> list[dict]:
    out = []
    for v in db.fetch_all(RECENT_VISITS_SQL, {"hid": household_id}):
        d = {"id": v["id"], "household_id": str(v["household_id"]),
             "target_id": str(v["target_id"]) if v.get("target_id") else None,
             "visited_at": iso(v["visited_at"]), "result": v["result"], "status_after": v.get("status_after"),
             "note": v.get("note")}
        if v.get("responder_id"):
            d["responder"] = {"user_id": str(v["responder_id"]), "nickname": v.get("responder_nickname")}
        out.append(d)
    return out


# ------------------------------------------------------------------ 저장
FIELDS = ("label", "address", "phone", "members", "needs", "note", "caregiver_user_id", "active")

UPSERT_SELF_SQL = """
INSERT INTO care.households (label, address, geom, phone, members, needs, note, linked_user_id, source,
                             consent_at, consent_method, consent_by, consent_version, created_by)
VALUES (%(label)s, %(address)s, ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326), %(phone)s, %(members)s,
        %(needs)s::text[], %(note)s, %(uid)s, 'self', now(), 'app', '본인', %(ver)s, %(uid)s)
ON CONFLICT (linked_user_id) DO UPDATE SET
  label = EXCLUDED.label, address = EXCLUDED.address, geom = EXCLUDED.geom, phone = EXCLUDED.phone,
  members = EXCLUDED.members, needs = EXCLUDED.needs, note = EXCLUDED.note, active = true,
  consent_at = now(), consent_method = 'app', consent_by = '본인', consent_version = EXCLUDED.consent_version,
  updated_at = now()
RETURNING id
"""


def upsert_self(user_id: str, data: dict, default_label: str) -> str:
    """본인 등록·수정 — 수정할 때마다 앱 동의를 다시 받은 것으로 기록 (동의 일시·버전 갱신)"""
    loc = data["location"]
    row = db.fetch_one(UPSERT_SELF_SQL, {
        "label": data.get("label") or default_label, "address": data.get("address"), "lat": loc["lat"], "lng": loc["lng"],
        "phone": data.get("phone"), "members": data.get("members") or 1, "needs": list(data.get("needs") or []),
        "note": data.get("note"), "uid": user_id, "ver": CONSENT_VERSION})
    return str(row["id"])


CREATE_SQL = """
INSERT INTO care.households (label, address, geom, phone, members, needs, note, caregiver_user_id, source,
                             consent_at, consent_method, consent_by, consent_version, created_by)
VALUES (%(label)s, %(address)s, ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326), %(phone)s, %(members)s,
        %(needs)s::text[], %(note)s, %(caregiver)s, %(source)s, now(), %(method)s, %(by)s, %(ver)s, %(created_by)s)
RETURNING id
"""


def create(data: dict, source: str, caregiver: Optional[str], created_by: str) -> str:
    loc = data["location"]
    row = db.fetch_one(CREATE_SQL, {
        "label": data["label"], "address": data.get("address"), "lat": loc["lat"], "lng": loc["lng"],
        "phone": data.get("phone"), "members": data.get("members") or 1, "needs": list(data.get("needs") or []),
        "note": data.get("note"), "caregiver": caregiver, "source": source, "method": data["consent_method"],
        "by": data["consent_by"], "ver": CONSENT_VERSION, "created_by": created_by})
    return str(row["id"])


def update(household_id: str, data: dict) -> None:
    sets, p = [], {"hid": household_id}
    for k in FIELDS:
        if k in data:
            sets.append(f"{k} = %({k})s" + ("::text[]" if k == "needs" else ""))
            p[k] = list(data[k]) if k == "needs" and data[k] is not None else (
                str(data[k]) if k == "caregiver_user_id" and data[k] else data[k])
    if data.get("location"):
        sets.append("geom = ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326)")
        p.update(data["location"])
    if sets:
        db.execute(f"UPDATE care.households SET {', '.join(sets)}, updated_at = now() WHERE id = %(hid)s", p)


def delete(household_id: str) -> int:
    return db.execute("DELETE FROM care.households WHERE id = %(hid)s", {"hid": household_id})


def check_caregiver(user_id: Optional[str]) -> None:
    """담당 생활지원사로 지정하려는 사용자가 실제로 caregiver 역할인지"""
    if user_id is None:
        return
    r = db.fetch_one("SELECT role::text AS role FROM users WHERE id = %(u)s", {"u": str(user_id)})
    if not r or r["role"] != "caregiver":
        raise ApiError("VALIDATION_ERROR", "담당자는 생활지원사 역할인 사용자여야 합니다.", detail="caregiver_user_id")
