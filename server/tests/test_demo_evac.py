"""시연 대피 응답 (2026-10-12) — 서버 저장 · 다른 계정 방재단원 화면이 읽기 · 방재단 출동 기록 (DB 없이, FakeDB)"""
from datetime import datetime, timezone

from conftest import AUTH
from test_alerts import UID, assert_spec

NOW = datetime(2026, 10, 12, 3, 0, tzinfo=timezone.utc)
OTHER = "7b1d2c3e-4f50-4a6b-8c7d-9e0f1a2b3c4d"
RESPONDER = {"Authorization": "Bearer dev:responder-other-account"}   # dev uid 가 responder 로 시작 = 방재단 역할
ROWS_KEY = "FROM care.demo_evac d JOIN users u"


def _row(uid, status="no_response", **kw):
    return {"user_id": uid, "nickname": kw.get("nickname"), "status": status, "needs": kw.get("needs", []),
            "started_at": NOW, "responded_at": None if status == "no_response" else NOW, "updated_at": NOW,
            "dispatch": kw.get("dispatch"), "dispatch_by": kw.get("by"), "minutes": 4}


def _me(fake_db, uid=UID):
    fake_db.rows["INSERT INTO users (firebase_uid"] = [{"id": uid, "created": False}]
    fake_db.rows["SELECT id FROM users WHERE firebase_uid"] = [{"id": uid}]


def _sql(fake_db, part):
    return [(sql, p) for sql, p in fake_db.executed if part in sql]


def test_start_resets_my_row_and_logs(client, fake_db):
    _me(fake_db)
    fake_db.rows[ROWS_KEY] = [_row(UID, needs=["mobility_limited"])]
    r = client.post("/api/v1/demo/evacuation/start", json={"needs": ["mobility_limited"]}, headers=AUTH)
    assert r.status_code == 200, r.text
    d = r.json()
    assert_spec(d, "/demo/evacuation/start", "post")
    assert d["id"] == f"demo-user-{UID}" and d["status"] == "no_response" and d["is_me"] and d["dispatch"] is None
    (sql, p), = _sql(fake_db, "INSERT INTO care.demo_evac (")
    assert "dispatch = NULL" in sql and p == {"uid": UID, "needs": ["mobility_limited"], "lat": None, "lng": None, "email_id": None}
    (_, log), = _sql(fake_db, "INSERT INTO care.demo_evac_log")
    assert log["kind"] == "start" and log["uid"] == UID


def test_response_is_saved_with_history(client, fake_db):
    _me(fake_db)
    fake_db.rows[ROWS_KEY] = [_row(UID, "need_help", needs=["vision"])]
    r = client.post("/api/v1/demo/evacuation/response", json={"status": "need_help", "needs": ["vision"], "via": "alarm"},
                    headers=AUTH)
    assert r.status_code == 200, r.text
    assert_spec(r.json(), "/demo/evacuation/response", "post")
    assert r.json()["status"] == "need_help"
    (_, p), = _sql(fake_db, "INSERT INTO care.demo_evac (user_id, status, needs, responded_at")
    assert p == {"uid": UID, "status": "need_help", "needs": ["vision"], "lat": None, "lng": None, "email_id": None}
    (_, log), = _sql(fake_db, "INSERT INTO care.demo_evac_log")
    assert (log["kind"], log["status"], log["via"]) == ("response", "need_help", "alarm")
    # 실제 대피 상황 표에는 쓰지 않는다 (FCM·이관 없음)
    assert not any("incident_targets" in sql or "evacuation_responses" in sql for sql, _ in fake_db.executed)


def test_response_validation_and_auth(client, fake_db):
    _me(fake_db)
    assert client.post("/api/v1/demo/evacuation/response", json={"status": "no_response"}, headers=AUTH).status_code == 422
    assert client.post("/api/v1/demo/evacuation/response", json={"status": "evacuated", "needs": ["elderly"]},
                       headers=AUTH).status_code == 422
    assert client.post("/api/v1/demo/evacuation/response", json={"status": "evacuated"}).status_code == 401
    assert client.get("/api/v1/demo/evacuation/responses").status_code == 401


def test_other_account_sees_responses_without_personal_fields(client, fake_db):
    _me(fake_db, OTHER)          # 방재단원 모드 계정
    fake_db.rows[ROWS_KEY] = [_row(UID, "evacuating", nickname="하린", needs=["hearing"]), _row(OTHER)]
    r = client.get("/api/v1/demo/evacuation/responses", headers=RESPONDER)
    assert r.status_code == 200
    d = r.json()
    assert_spec(d, "/demo/evacuation/responses")
    a, b = d
    assert (a["label"], a["status"], a["needs"], a["is_me"]) == ("하린", "evacuating", ["hearing"], False)
    assert b["is_me"] and b["label"].startswith("시연 주민 ")
    assert a["location"] != b["location"]              # 지도 표시가 겹치지 않게 다른 자리
    assert not {"address", "phone", "home"} & set(a)


def test_responder_side_open_without_role(client, fake_db):
    """시연 모드는 방재단 전용 코드 없이 방재단원 모드 — 응답 목록·출동 기록은 로그인만 있으면 된다 (2026-10-13)"""
    _me(fake_db)
    fake_db.rows[ROWS_KEY] = [_row(UID, "need_help")]
    assert client.get("/api/v1/demo/evacuation/responses", headers=AUTH).status_code == 200
    body = {"departed_at": "2026-10-12T12:00:00+09:00", "eta": "2026-10-12T12:07:00+09:00", "stage": "en_route"}
    assert client.put(f"/api/v1/demo/evacuation/demo-user-{UID}/dispatch", json=body, headers=AUTH).status_code == 204
    assert _sql(fake_db, "UPDATE care.demo_evac SET dispatch")
    assert client.delete(f"/api/v1/demo/evacuation/demo-user-{UID}/dispatch", headers=AUTH).status_code == 204


def test_me_returns_dispatch_or_null(client, fake_db):
    _me(fake_db)
    disp = {"departed_at": "2026-10-12T12:00:00+09:00", "eta": "2026-10-12T12:07:00+09:00", "responder": "시연 방재단원",
            "stage": "en_route"}
    fake_db.rows[ROWS_KEY] = [_row(UID, "need_help", dispatch=disp)]
    d = client.get("/api/v1/demo/evacuation/me", headers=AUTH).json()
    assert_spec(d, "/demo/evacuation/me")
    assert d["dispatch"] == disp and d["dispatch_by_me"] is False
    fake_db.rows[ROWS_KEY] = [_row(UID, "need_help", dispatch=disp, by=OTHER)]
    _me(fake_db, OTHER)
    a, = client.get("/api/v1/demo/evacuation/responses", headers=RESPONDER).json()
    assert a["dispatch_by_me"] is True and not a["is_me"]
    _me(fake_db)
    fake_db.rows[ROWS_KEY] = []
    r = client.get("/api/v1/demo/evacuation/me", headers=AUTH)
    assert r.status_code == 200 and r.json() is None


def test_dispatch_write_clear_and_missing(client, fake_db, monkeypatch):
    _me(fake_db, OTHER)
    body = {"departed_at": "2026-10-12T12:00:00+09:00", "eta": "2026-10-12T12:07:00+09:00", "stage": "en_route"}
    r = client.put(f"/api/v1/demo/evacuation/demo-user-{UID}/dispatch", json=body, headers=RESPONDER)
    assert r.status_code == 204, r.text
    (sql, p), = _sql(fake_db, "UPDATE care.demo_evac SET dispatch")
    assert p["tid"] == UID and p["by"] == OTHER and '"en_route"' in p["d"]
    (_, log), = _sql(fake_db, "INSERT INTO care.demo_evac_log")
    assert (log["kind"], log["status"], log["uid"], log["by"]) == ("dispatch", "en_route", UID, OTHER)
    assert client.delete(f"/api/v1/demo/evacuation/demo-user-{UID}/dispatch", headers=RESPONDER).status_code == 204
    assert _sql(fake_db, "UPDATE care.demo_evac SET dispatch")[-1][1]["d"] is None
    assert client.put("/api/v1/demo/evacuation/demo-user-nope/dispatch", json=body, headers=RESPONDER).status_code == 404
    # 진행 중인 시연 응답이 없으면(0행) 404
    from app import db
    monkeypatch.setattr(db, "execute", lambda sql, p=None: 0)
    assert client.put(f"/api/v1/demo/evacuation/{UID}/dispatch", json=body, headers=RESPONDER).status_code == 404


# 2026-10-12 사용자 요청: 방재단 현황에 주민의 실제 위치
def test_real_location_is_saved_and_returned(client, fake_db):
    _me(fake_db)
    fake_db.rows[ROWS_KEY] = [_row(UID, "need_help", needs=["vision"]) | {"lat": 35.9871, "lng": 129.5522, "location_at": NOW}]
    r = client.post("/api/v1/demo/evacuation/response",
                    json={"status": "need_help", "needs": ["vision"], "location": {"lat": 35.9871, "lng": 129.5522}}, headers=AUTH)
    assert r.status_code == 200, r.text
    d = r.json()
    assert_spec(d, "/demo/evacuation/response", "post")
    assert d["location"] == {"lat": 35.9871, "lng": 129.5522} and d["location_source"] == "app"
    (_, p), = _sql(fake_db, "INSERT INTO care.demo_evac (user_id, status, needs, responded_at")
    assert (p["lat"], p["lng"]) == (35.9871, 129.5522)
    # 위치 없이 응답하면 lat·lng 는 None → 서버가 이전 위치를 지킨다 (COALESCE)
    client.post("/api/v1/demo/evacuation/response", json={"status": "evacuating"}, headers=AUTH)
    sql, p = _sql(fake_db, "INSERT INTO care.demo_evac (user_id, status, needs, responded_at")[-1]
    assert p["lat"] is None and "COALESCE(EXCLUDED.lat" in sql


def test_virtual_location_without_app_location(client, fake_db):
    _me(fake_db, OTHER)
    fake_db.rows[ROWS_KEY] = [_row(UID, "need_help")]
    a, = client.get("/api/v1/demo/evacuation/responses", headers=RESPONDER).json()
    assert a["location_source"] == "demo" and a["location_at"] is None


def test_location_update(client, fake_db, monkeypatch):
    _me(fake_db)
    r = client.post("/api/v1/demo/evacuation/location", json={"location": {"lat": 35.99, "lng": 129.55}}, headers=AUTH)
    assert r.status_code == 204, r.text
    (_, p), = _sql(fake_db, "UPDATE care.demo_evac SET lat")
    assert (p["uid"], p["lat"], p["lng"]) == (UID, 35.99, 129.55)
    assert not _sql(fake_db, "demo_evac_log")                    # 위치는 이력을 남기지 않는다
    assert client.post("/api/v1/demo/evacuation/location", json={"location": {"lat": 99, "lng": 129}},
                       headers=AUTH).status_code == 422
    from app import db
    monkeypatch.setattr(db, "execute", lambda sql, p=None: 0)
    assert client.post("/api/v1/demo/evacuation/location", json={"location": {"lat": 35.99, "lng": 129.55}},
                       headers=AUTH).status_code == 404


# 2026-10-12 사용자 요청: 방재단 화면의 이름 = 시연 주민의 이메일 아이디
def test_label_is_email_id_from_token(client, fake_db):
    from app.demo_evac import email_id
    assert email_id("harin@gmail.com") == "harin" and email_id(None) is None and email_id("") is None
    _me(fake_db)
    fake_db.rows[ROWS_KEY] = [_row(UID, "need_help", nickname="별명") | {"email_id": "harin"}]
    r = client.post("/api/v1/demo/evacuation/response", json={"status": "need_help"},
                    headers={"Authorization": "Bearer dev:harin@gmail.com"})
    assert r.status_code == 200 and r.json()["label"] == "harin"          # 이메일 아이디가 별명보다 먼저
    (sql, p), = _sql(fake_db, "INSERT INTO care.demo_evac (user_id, status, needs, responded_at")
    assert p["email_id"] == "harin" and "COALESCE(EXCLUDED.email_id" in sql
    fake_db.rows[ROWS_KEY] = [_row(UID, "need_help", nickname="별명")]
    assert client.get("/api/v1/demo/evacuation/me", headers=AUTH).json()["label"] == "별명"


# 2026-10-12 사용자 요청: 시연 모드를 껐다 켜면 서버의 시연 주민 초기화
def test_reset_all_demo_residents(client, fake_db):
    assert client.delete("/api/v1/demo/evacuation").status_code == 401
    assert client.delete("/api/v1/demo/evacuation", headers=AUTH).status_code == 204
    (sql, _), = _sql(fake_db, "DELETE FROM care.demo_evac")
    assert "demo_evac_log" not in sql                      # 이력은 남긴다
