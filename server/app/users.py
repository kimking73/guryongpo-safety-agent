"""사용자 정보 (A5) — users · user_profiles · user_places · emergency_contacts · user_devices

라우터(/user*, /device-token, /alerts)와 경고 파이프라인이 같이 쓴다.
응답 모양은 명세 User (mock/user.json 과 같음). Firebase uid 로 사용자 행을 찾고, 없으면 만든다.
"""
from __future__ import annotations

from typing import Optional

from . import db
from .auth import AuthUser
from .errors import ApiError
from .mocks import iso

# 명세 ProfileInput 에서 null 을 허용하는 항목 — 나머지는 값이 없으면 응답에서 뺀다 (enum·boolean 에 null 금지)
NULLABLE = {"occupation", "blood_type", "dependents_note", "medical_note"}
PROFILE_COLS = ["user_type", "birth_year", "mobility", "occupation", "owns_vessel", "walking_ability",
                "vision_impaired", "hearing_impaired", "has_dependents", "dependents_note", "prefers_voice", "language"]
# 건강 정보는 care.user_health (AI 읽기 전용 계정이 못 읽는 스키마, 2026-10-04 A13) — 응답에서는 profile 안에 그대로
HEALTH_COLS = ["blood_type", "medical_note"]
ENUM_CAST = {"user_type": "user_type", "mobility": "mobility_mode", "walking_ability": "walking_ability"}

ENSURE_SQL = """
INSERT INTO users (firebase_uid, is_anonymous, last_active_at) VALUES (%(uid)s, %(anon)s, now())
ON CONFLICT (firebase_uid) DO UPDATE SET last_active_at = now(),
    is_anonymous = EXCLUDED.is_anonymous   -- 익명 계정에 Google·이메일을 연결하면 uid는 그대로, 익명 표시만 해제
RETURNING id, (xmax = 0) AS created
"""


def ensure_user(u: AuthUser) -> tuple[str, bool]:
    """uid → (user_id, 새로 만들었는지)"""
    row = db.fetch_one(ENSURE_SQL, {"uid": u.uid, "anon": u.is_anonymous})
    if not row:
        raise ApiError("UPSTREAM_UNAVAILABLE", detail="user_upsert_failed")
    return str(row["id"]), bool(row.get("created"))


def find_user_id(u: AuthUser) -> Optional[str]:
    row = db.fetch_one("SELECT id FROM users WHERE firebase_uid = %(uid)s", {"uid": u.uid})
    return str(row["id"]) if row else None


def require_user_id(u: AuthUser) -> str:
    uid = find_user_id(u)
    if uid is None:
        raise ApiError("NOT_FOUND", "등록된 사용자가 없습니다. 먼저 POST /user 를 호출하세요.", detail="user_not_registered")
    return uid


# ------------------------------------------------------------------ 프로필
def save_profile(user_id: str, data: dict) -> None:
    """보낸 항목만 저장 (PATCH 의미). alert_prefs 는 jsonb 병합. 별명은 users, 혈액형·병력 메모는 care.user_health"""
    if "nickname" in data:
        db.execute("UPDATE users SET nickname = %(n)s WHERE id = %(uid)s", {"n": data["nickname"], "uid": user_id})
    health = [c for c in HEALTH_COLS if c in data]
    if health:
        db.execute(f"""
            INSERT INTO care.user_health (user_id, {", ".join(health)}) VALUES (%(uid)s, {", ".join(f"%({c})s" for c in health)})
            ON CONFLICT (user_id) DO UPDATE SET {", ".join(f"{c} = EXCLUDED.{c}" for c in health)}, updated_at = now()""",
                   {"uid": user_id, **{c: data[c] for c in health}})
    cols = [c for c in PROFILE_COLS if c in data]
    prefs = data.get("alert_prefs")
    if not cols and prefs is None:
        return
    params = {"uid": user_id, **{c: data[c] for c in cols}}
    names = ", ".join(cols + (["alert_prefs"] if prefs is not None else []))
    vals = ", ".join([f"%({c})s" + (f"::{ENUM_CAST[c]}" if c in ENUM_CAST else "") for c in cols]
                     + (["%(prefs)s::jsonb"] if prefs is not None else []))
    sets = ", ".join([f"{c} = EXCLUDED.{c}" for c in cols]
                     + (["alert_prefs = user_profiles.alert_prefs || EXCLUDED.alert_prefs"] if prefs is not None else []))
    if prefs is not None:
        import json
        params["prefs"] = json.dumps({k: v for k, v in prefs.items() if v is not None})
    db.execute(f"""
        INSERT INTO user_profiles (user_id, {names}) VALUES (%(uid)s, {vals})
        ON CONFLICT (user_id) DO UPDATE SET {sets}, updated_at = now()""", params)


APP_STATE_MAX_BYTES = 64 * 1024


def load_app_state(user_id: str) -> dict:
    r = db.fetch_one("SELECT app_state, app_state_at FROM user_profiles WHERE user_id = %(uid)s", {"uid": user_id})
    return {"state": (r or {}).get("app_state"), "updated_at": iso((r or {}).get("app_state_at"))}


def save_app_state(user_id: str, state: dict) -> None:
    """앱 입력값 통째 저장 (덮어쓰기). 너무 크면 거절"""
    import json
    raw = json.dumps(state, ensure_ascii=False)
    if len(raw.encode()) > APP_STATE_MAX_BYTES:
        raise ApiError("VALIDATION_ERROR", "저장할 정보가 너무 큽니다.", detail="app_state_too_large")
    db.execute("""
        INSERT INTO user_profiles (user_id, app_state, app_state_at) VALUES (%(uid)s, %(s)s::jsonb, now())
        ON CONFLICT (user_id) DO UPDATE SET app_state = EXCLUDED.app_state, app_state_at = now(), updated_at = now()""",
               {"uid": user_id, "s": raw})


def default_alert_prefs(p: dict) -> dict:
    """저장값이 없으면 시각장애 → tts, 청각장애 → 강한 진동 + 화면 깜빡임 (01m_v0_3.sql 규칙)"""
    saved = p.get("alert_prefs") or {}
    base = {"tts": bool(p.get("vision_impaired") or p.get("prefers_voice")),
            "strong_vibration": bool(p.get("hearing_impaired")), "screen_flash": bool(p.get("hearing_impaired")),
            "large_text": False}
    return {**base, **{k: v for k, v in saved.items() if k in base and isinstance(v, bool)}}


# ------------------------------------------------------------------ 조회 (명세 User)
USER_SQL = """
SELECT u.id, u.firebase_uid, u.is_anonymous, u.role::text AS role, u.created_at,
       u.nickname, p.user_type::text AS user_type, p.birth_year, p.mobility::text AS mobility, p.occupation,
       p.owns_vessel, p.walking_ability::text AS walking_ability, p.vision_impaired, p.hearing_impaired, uh.blood_type,
       p.has_dependents, p.dependents_note, uh.medical_note, p.prefers_voice, p.language, p.alert_prefs,
       (p.user_id IS NOT NULL) AS has_profile
FROM users u LEFT JOIN user_profiles p ON p.user_id = u.id LEFT JOIN care.user_health uh ON uh.user_id = u.id
WHERE u.id = %(uid)s
"""
# 정적 위험지역 안이면 그 재난 — 산사태: 지정 취약지역 지점 100m 안 (판정 범위와 같음), 그 밖: 폴리곤 안
PLACES_SQL = """
SELECT pl.id, pl.place_type::text AS place_type, pl.label, pl.address, pl.notify,
       ST_Y(pl.geom) AS lat, ST_X(pl.geom) AS lng,
       ARRAY(SELECT DISTINCT hz.hazard::text FROM hazard_zones hz
             WHERE CASE WHEN hz.hazard = 'landslide'
                        THEN ST_DWithin(pl.geom::geography, ST_PointOnSurface(hz.geom)::geography, 100)
                        ELSE ST_Intersects(hz.geom, pl.geom) END) AS in_hazard_zones
FROM user_places pl WHERE pl.user_id = %(uid)s {extra}
ORDER BY pl.created_at, pl.id
"""
CONTACTS_SQL = """
SELECT id, name, relation, phone, priority FROM emergency_contacts WHERE user_id = %(uid)s ORDER BY priority, name
"""
HOUSEHOLD_SQL = "SELECT id, needs FROM care.households WHERE linked_user_id = %(uid)s AND active"


def place_out(r: dict) -> dict:
    return {"id": str(r["id"]), "place_type": r["place_type"], "label": r["label"], "address": r.get("address"),
            "location": {"lat": r["lat"], "lng": r["lng"]}, "notify": bool(r["notify"]),
            "in_hazard_zones": list(r.get("in_hazard_zones") or [])}


def contact_out(r: dict) -> dict:
    return {"id": str(r["id"]), "name": r["name"], "relation": r.get("relation"), "phone": r["phone"],
            "priority": r.get("priority") or 1}


def places(user_id: str, place_id: Optional[str] = None) -> list[dict]:
    extra = "AND pl.id = %(pid)s" if place_id else ""
    return [place_out(r) for r in db.fetch_all(PLACES_SQL.format(extra=extra), {"uid": user_id, "pid": place_id})]


def load_user(user_id: str) -> dict:
    r = db.fetch_one(USER_SQL, {"uid": user_id})
    if not r:
        raise ApiError("NOT_FOUND", detail="user_not_found")
    profile = {"nickname": r["nickname"]} if r.get("nickname") else {}
    for c in PROFILE_COLS + HEALTH_COLS:
        v = r.get(c)
        if c == "language":
            continue                              # 명세 ProfileInput 에 없음 (저장만)
        if v is not None or c in NULLABLE:
            profile[c] = v
    profile["alert_prefs"] = default_alert_prefs(r)
    pl = places(user_id)
    hh = db.fetch_one(HOUSEHOLD_SQL, {"uid": user_id})
    missing = [k for k in ("birth_year", "mobility") if r.get(k) is None]    # 명세 onboarding.missing (user_type 은 입력에서 빠짐)
    # 집 또는 숙소 중 하나 — 숙소를 등록한 사람(관광객)은 집을 요구하지 않음 (2026-10-04, 사용자 유형 입력 대신)
    if r.get("user_type") != "tourist" and not any(p["place_type"] in ("home", "lodging") for p in pl):
        missing.append("home_place")
    return {
        "id": str(r["id"]), "firebase_uid": r["firebase_uid"], "is_anonymous": bool(r["is_anonymous"]),
        "role": r.get("role") or "resident", "profile": profile,
        "household": {"id": str(hh["id"]), "needs": list(hh["needs"] or [])} if hh else None,
        "places": pl, "contacts": [contact_out(c) for c in db.fetch_all(CONTACTS_SQL, {"uid": user_id})],
        "onboarding": {"completed": not missing, "missing": missing},
        "created_at": iso(r.get("created_at")),
    }


# ------------------------------------------------------------------ 기기 (FCM 토큰 · 폴링 위치)
# 같은 토큰이 다른 계정에 있으면 이 계정으로 옮김 (앱 재설치·익명 계정 재생성) — 같은 uid+토큰이면 같은 device_id
DEVICE_SQL = """
INSERT INTO user_devices (user_id, platform, fcm_token) VALUES (%(uid)s, %(platform)s, %(token)s)
ON CONFLICT (fcm_token) DO UPDATE SET user_id = EXCLUDED.user_id, platform = EXCLUDED.platform
RETURNING id
"""


def register_device(user_id: str, token: str, platform: str) -> str:
    row = db.fetch_one(DEVICE_SQL, {"uid": user_id, "token": token, "platform": platform})
    if not row:
        raise ApiError("UPSTREAM_UNAVAILABLE", detail="device_upsert_failed")
    return str(row["id"])


def report_location(user_id: str, device_id: Optional[str], lat: float, lng: float) -> None:
    """폴링 위치 보고 → user_devices.last_location. device_id 가 없거나 남의 기기면 푸시 없는 위치 전용 기기 1개를 씀"""
    params = {"uid": user_id, "did": device_id, "lat": lat, "lng": lng}
    n = 0
    if device_id:
        n = db.execute("""UPDATE user_devices SET last_location = ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326),
                          last_location_at = now() WHERE id = %(did)s AND user_id = %(uid)s""", params)
    if not n:
        n = db.execute("""UPDATE user_devices SET last_location = ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326),
                          last_location_at = now() WHERE user_id = %(uid)s AND fcm_token IS NULL""", params)
    if not n:
        db.execute("""INSERT INTO user_devices (user_id, platform, last_location, last_location_at)
                      VALUES (%(uid)s, 'web', ST_SetSRID(ST_MakePoint(%(lng)s, %(lat)s), 4326), now())""", params)
