"""A13 취약 가구 — 동의 필수 · 본인 등록 · 대리 등록 · 생활지원사 담당 가구만 · 건강 정보 care 이동 (DB 없이, FakeDB)"""
from datetime import datetime, timedelta, timezone

import pytest

from conftest import AUTH
from test_alerts import UID, assert_spec

NOW = datetime(2026, 10, 4, 5, 0, tzinfo=timezone.utc)
STAFF = {"Authorization": "Bearer dev:responder-1"}
CAREGIVER = {"Authorization": "Bearer dev:caregiver-1"}
STAFF_ID = "11111111-2222-4333-8444-555555555555"
HID = "e7f8a9b0-c1d2-4e3f-9a4b-5c6d7e8f9a0b"
CG_ID = "22222222-3333-4444-8555-666666666666"

HH_ROW = {"id": HID, "label": "삼정리 김OO 어르신 댁", "address": "구룡포읍", "lat": 35.98, "lng": 129.55, "phone": None,
          "members": 1, "needs": ["elderly", "living_alone"], "linked_user_id": None, "caregiver_user_id": CG_ID,
          "caregiver_nickname": "생활지원사 박OO", "source": "caregiver", "consent_at": NOW, "consent_method": "written",
          "consent_by": "본인", "consent_version": "v1", "note": None, "active": True, "updated_at": NOW,
          "landslide_g1_m": 40, "landslide_designated": None, "landslide_g12": True}
HH_KEY = "FROM care.households h\nLEFT JOIN users cu"


def _user(fake_db):
    fake_db.rows["SELECT id FROM users WHERE firebase_uid"] = [{"id": UID}]
    fake_db.rows["INSERT INTO users (firebase_uid"] = [{"id": STAFF_ID, "created": False}]


# ------------------------------------------------------------------ 표시
@pytest.mark.parametrize("row,label", [
    ({"landslide_g1_m": 40}, "산사태위험지도 1등급 비탈 40m"),
    ({"landslide_designated": "병포리 산1-2임"}, "산사태 취약지역 (병포리 산1-2임)"),
    ({"landslide_g12": True}, "산사태위험지도 1·2등급 비탈 100m 이내"),
    ({}, None),
])
def test_landslide_label(row, label):
    from app.households import landslide_label
    assert landslide_label(row) == label


# ------------------------------------------------------------------ 본인 등록
def test_self_household_requires_consent(client, fake_db):
    _user(fake_db)
    body = {"location": {"lat": 35.98, "lng": 129.55}, "members": 1, "needs": ["elderly"]}
    assert client.put("/api/v1/user/household", headers=AUTH, json=body).status_code == 422
    assert client.put("/api/v1/user/household", headers=AUTH, json={**body, "consent": False}).status_code == 422
    assert not any("care.households" in sql for sql, _ in fake_db.executed)          # 동의 없이는 저장 안 함


def test_self_household_register_and_withdraw(client, fake_db, monkeypatch):
    from app import users
    _user(fake_db)
    monkeypatch.setattr(users, "load_user", lambda uid: {"profile": {"nickname": "하린"}})
    seen = []
    from app import db
    orig = db.fetch_one
    monkeypatch.setattr(db, "fetch_one", lambda sql, p=None: seen.append((sql, p)) or orig(sql, p))
    fake_db.rows["INSERT INTO care.households (label, address, geom, phone, members, needs, note, linked_user_id"] = [{"id": HID}]
    fake_db.rows[HH_KEY] = [{**HH_ROW, "linked_user_id": UID, "source": "self", "consent_method": "app",
                             "caregiver_user_id": None}]
    r = client.put("/api/v1/user/household", headers=AUTH, json={
        "location": {"lat": 35.98, "lng": 129.55}, "needs": ["elderly"], "consent": True})
    assert r.status_code == 200
    assert_spec(r.json(), "/user/household", "put")
    assert r.json()["consent"] == {"at": NOW.astimezone(timezone(timedelta(hours=9))).isoformat(timespec="seconds"),
                                   "method": "app", "by": "본인", "version": "v1"}
    up = next(p for sql, p in seen if "ON CONFLICT (linked_user_id)" in sql)
    assert up["label"] == "하린 댁" and up["ver"] == "v1" and up["uid"] == UID
    assert client.get("/api/v1/user/household", headers=AUTH).json()["has_app"] is True
    assert client.delete("/api/v1/user/household", headers=AUTH).status_code == 204
    deleted = [sql for sql, _ in fake_db.executed if "DELETE FROM care.households" in sql]
    assert deleted and "source = 'self'" in deleted[0]                  # 대리 등록 가구는 연결만 끊음


def test_self_household_not_registered(client, fake_db):
    _user(fake_db)
    r = client.get("/api/v1/user/household", headers=AUTH)
    assert r.status_code == 404 and r.json()["detail"] == "household_not_registered"


# ------------------------------------------------------------------ 방재단·생활지원사
def test_admin_households_list_and_detail(client, fake_db):
    _user(fake_db)
    fake_db.rows[HH_KEY] = [HH_ROW]
    fake_db.rows["FROM care.visit_logs v LEFT JOIN users u"] = [
        {"id": 3, "household_id": HID, "target_id": None, "visited_at": NOW, "result": "not_home", "status_after": None,
         "note": None, "responder_id": STAFF_ID, "responder_nickname": "방재단 김OO"}]
    lst = client.get("/api/v1/admin/households", headers=STAFF, params={"needs": "living_alone", "q": "삼정리"}).json()
    assert_spec(lst, "/admin/households")
    assert lst[0]["landslide_zone"] == "산사태위험지도 1등급 비탈 40m" and lst[0]["caregiver"]["nickname"] == "생활지원사 박OO"
    d = client.get(f"/api/v1/admin/households/{HID}", headers=STAFF).json()
    assert_spec(d, "/admin/households/{household_id}")
    assert d["recent_visits"][0]["result"] == "not_home"


def test_caregiver_scope(client, fake_db, monkeypatch):
    """생활지원사는 담당 가구만 — 목록·상세·수정·삭제 모두 본인 id 로 거름. 남의 가구는 404"""
    from app import db
    _user(fake_db)
    seen = []
    orig_all, orig_one = db.fetch_all, db.fetch_one
    monkeypatch.setattr(db, "fetch_all", lambda sql, p=None: seen.append(p) or orig_all(sql, p))
    monkeypatch.setattr(db, "fetch_one", lambda sql, p=None: seen.append(p) or orig_one(sql, p))
    client.get("/api/v1/admin/households", headers=CAREGIVER)
    assert any(p and p.get("cg") == STAFF_ID for p in seen)
    assert client.get(f"/api/v1/admin/households/{HID}", headers=CAREGIVER).status_code == 404     # 담당 아님
    assert client.patch(f"/api/v1/admin/households/{HID}", headers=CAREGIVER, json={"note": "x"}).status_code == 404
    assert client.delete(f"/api/v1/admin/households/{HID}", headers=CAREGIVER).status_code == 404
    assert client.get("/api/v1/admin/households", headers=AUTH).status_code == 403                 # 일반 주민


def test_admin_create_household(client, fake_db, monkeypatch):
    from app import db
    _user(fake_db)
    seen = []
    orig = db.fetch_one
    monkeypatch.setattr(db, "fetch_one", lambda sql, p=None: seen.append((sql, p)) or orig(sql, p))
    fake_db.rows["INSERT INTO care.households (label, address, geom, phone, members, needs, note, caregiver_user_id"] = [{"id": HID}]
    fake_db.rows[HH_KEY] = [HH_ROW]
    body = {"label": "삼정리 이OO 댁", "location": {"lat": 35.98, "lng": 129.55}, "needs": ["elderly", "hearing"],
            "consent_method": "written", "consent_by": "본인"}
    r = client.post("/api/v1/admin/households", headers=CAREGIVER, json=body)
    assert r.status_code == 201
    assert_spec(r.json(), "/admin/households", "post", "201")
    ins = next(p for sql, p in seen if "caregiver_user_id, source" in sql)
    assert ins["source"] == "caregiver" and ins["caregiver"] == STAFF_ID and ins["method"] == "written" and ins["ver"] == "v1"
    # 동의 기록 없이는 등록 불가 · 정해진 사정만
    assert client.post("/api/v1/admin/households", headers=STAFF, json={**body, "needs": ["unknown"]}).status_code == 422
    assert client.post("/api/v1/admin/households", headers=STAFF,
                       json={k: v for k, v in body.items() if k != "consent_by"}).status_code == 422
    assert client.post("/api/v1/admin/households", headers=STAFF, json={**body, "consent_method": "app"}).status_code == 422
    # 담당자로 지정하려는 사용자가 생활지원사가 아니면 422
    fake_db.rows["SELECT role::text AS role FROM users WHERE id"] = [{"role": "resident"}]
    r = client.post("/api/v1/admin/households", headers=STAFF, json={**body, "caregiver_user_id": CG_ID})
    assert r.status_code == 422 and r.json()["detail"] == "caregiver_user_id"


def test_caregiver_cannot_reassign(client, fake_db):
    _user(fake_db)
    fake_db.rows[HH_KEY] = [HH_ROW]
    r = client.patch(f"/api/v1/admin/households/{HID}", headers=CAREGIVER, json={"caregiver_user_id": None})
    assert r.status_code == 403
    r = client.patch(f"/api/v1/admin/households/{HID}", headers=STAFF, json={"note": "출입문 비밀번호는 보호자에게", "active": False})
    assert r.status_code == 200
    upd = next(p for sql, p in fake_db.executed if "UPDATE care.households SET" in sql)
    assert upd["note"].startswith("출입문") and upd["active"] is False


# ------------------------------------------------------------------ 건강 정보는 care.user_health
def test_health_fields_go_to_care(client, fake_db):
    _user(fake_db)
    client.patch("/api/v1/user", headers=AUTH, json={"blood_type": "A+", "medical_note": "고혈압 약", "birth_year": 1958})
    sqls = [(sql, p) for sql, p in fake_db.executed]
    health = next(p for sql, p in sqls if "INSERT INTO care.user_health" in sql)
    assert health == {"uid": UID, "blood_type": "A+", "medical_note": "고혈압 약"}
    profile = next(sql for sql, p in sqls if "INSERT INTO user_profiles" in sql)
    assert "blood_type" not in profile and "medical_note" not in profile and "birth_year" in profile


def test_demo_households_scenario(client, fake_db):
    r = client.post("/api/v1/internal/simulate", json={"scenario": "demo_households"})
    from risk.simulate import DEMO_HOUSEHOLDS
    assert r.status_code == 202 and r.json()["accepted"] and r.json()["households"] == len(DEMO_HOUSEHOLDS) + 1   # FakeDB: 목록 + 산사태 1
    rows = next(rows for sql, rows in fake_db.executed if "시연용 가상 주소" in sql and isinstance(rows, list))
    assert all(x["label"].startswith("[시연] ") for x in rows)
    r = client.post("/api/v1/internal/simulate", json={"scenario": "demo_households_clear"})
    assert r.json()["scenario"] == "demo_households_clear"
