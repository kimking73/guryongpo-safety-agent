"""A5 선제 경고 — 경고 종류 판단·문구·FCM 형식·경고 생성·사용자/경고 API (DB 없이, FakeDB)"""
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from conftest import AUTH

KST = timezone(timedelta(hours=9))
NOW = datetime(2026, 10, 5, 14, 30, tzinfo=KST)
UID = "3f2a1c9e-8b7d-4e6f-a5c4-1d2e3f4a5b6c"
ALERT = "d1e2f3a4-b5c6-4d7e-8f90-a1b2c3d4e5f6"
INCIDENT = "c0ffee00-1d2e-4f30-9a41-5b6c7d8e9f01"


# ------------------------------------------------------------------ 명세 검증
def _validator(path, method, status, ctype="application/json"):
    yaml = pytest.importorskip("yaml")
    jsonschema = pytest.importorskip("jsonschema", minversion="4.18")
    spec = yaml.safe_load((Path(__file__).resolve().parent.parent / "spec" / "openapi.yaml").read_text(encoding="utf-8"))
    schema = spec["paths"][path][method]["responses"][status]["content"][ctype]["schema"]
    return jsonschema.Draft202012Validator({**spec, **schema}, format_checker=jsonschema.Draft202012Validator.FORMAT_CHECKER)


def assert_spec(data, path, method="get", status="200"):
    errors = [f"{e.json_path}: {e.message}" for e in _validator(path, method, status).iter_errors(data)]
    assert not errors, errors[:5]


# ------------------------------------------------------------------ 경고 종류 (사용자 결정 2026-10-03)
@pytest.mark.parametrize("hazard,level,kind", [
    ("flood", "warning", "evacuation"), ("flood", "critical", "evacuation"), ("flood", "advisory", "alert"),
    ("heavy_rain", "warning", "evacuation"), ("strong_wind", "warning", "evacuation"), ("typhoon", "warning", "evacuation"),
    ("landslide", "warning", "evacuation"), ("landslide", "advisory", "alert"),
    ("fine_dust", "warning", "alert"), ("uv", "critical", "alert"), ("high_seas", "warning", "alert"),
    ("uv", "watch", None), ("flood", "normal", None),
])
def test_classify(hazard, level, kind):
    from alerts.policy import classify
    assert classify(hazard, level) == kind


def test_evac_message_needs_guryongpo_and_order():
    from alerts.policy import is_evac_message, message_hazard
    assert is_evac_message("[포항시] 호우경보 발효. 구룡포읍 저지대 주민은 인근 대피소로 대피하시기 바랍니다")
    assert is_evac_message("구룡포 해안가 주민 즉시 대피")
    assert not is_evac_message("[포항시] 흥해읍 주민은 대피소로 대피하시기 바랍니다")          # 구룡포 아님
    assert not is_evac_message("[포항시] 구룡포 일대 강풍 주의, 외출 자제 바랍니다")             # 대피 지시 아님
    assert message_hazard(None, "태풍", "") == "typhoon"
    assert message_hazard("landslide", "호우", "") == "landslide"
    assert message_hazard(None, None, "구룡포 대피소로") == "heavy_rain"


# ------------------------------------------------------------------ 문구
def test_compose_evacuation_for_elderly_fisher():
    from alerts.messages import compose
    u = {"trigger": "place", "place_label": "우리집", "birth_year": 1950, "walking_ability": "limited",
         "occupation": "fisher", "owns_vessel": True, "contact": {"name": "김OO", "relation": "딸", "phone": "010-0000-0000"}}
    m = compose({"kind": "evacuation", "hazard": "flood", "level": "warning", "reason": "침수심 230mm"}, u)
    assert m["title"].startswith("[대피 확인] 침수 경보") and "'우리집'" in m["title"]
    assert "'도움 필요'" in m["body"] and "선박" in m["body"] and m["tts_text"]
    assert [a["type"] for a in m["actions"]] == ["respond", "open_route", "call", "call"]
    assert m["actions"][0]["params"]["buttons"] == ["evacuated", "evacuating", "need_help"]
    assert m["actions"][-1]["label"] == "딸에게 전화"
    assert {"elderly", "walking_limited", "fisher", "vessel_owner"} <= set(m["reason"]["profile_tags"])


def test_compose_alert_dust():
    from alerts.messages import compose
    m = compose({"kind": "alert", "hazard": "fine_dust", "level": "advisory", "reason": None},
                {"trigger": "current_location"})
    assert m["title"] == "[미세먼지 주의] 현재 위치" and "마스크" in m["body"]
    assert [a["type"] for a in m["actions"]] == ["open_checklist"]
    assert m["reason"] == {"trigger": "current_location", "place_label": None, "profile_tags": []}


def test_fcm_payload_strings():
    from alerts.fcm import payload
    d = payload("evacuation", alert_id=ALERT, incident_id=None, level_num=3, hazard="flood")
    assert d == {"kind": "evacuation", "alert_id": ALERT, "level_num": "3", "hazard": "flood"}
    assert all(isinstance(v, str) for v in d.values())


def test_fcm_skipped_without_firebase(monkeypatch):
    from alerts import fcm
    monkeypatch.setattr(fcm, "_app", lambda: None)
    s = fcm.send([fcm.Push(token="t", title="a", body="b", ref="x")])
    assert s["skipped"] == 1 and s["sent"] == 0 and not s["ok_refs"]


# ------------------------------------------------------------------ 경고 생성 (dispatch)
def _target(user, **kw):
    return {"user_id": user, "trigger": "current_location", "place_id": None, "place_label": None,
            "lat": 35.99, "lng": 129.556, "birth_year": None, "walking_ability": None, "mobility": None,
            "occupation": None, "owns_vessel": False, "vision_impaired": False, "hearing_impaired": False,
            "user_type": None, "contact": None, **kw}


@pytest.fixture
def spy(fake_db, monkeypatch):
    """fetch_one 호출의 (sql, params) 기록"""
    from app import db
    calls = []
    orig = db.fetch_one

    def fetch_one(sql, params=None):
        calls.append((sql, params))
        return orig(sql, params)
    monkeypatch.setattr(db, "fetch_one", fetch_one)
    return calls


def test_dispatch_picks_highest_level_per_hazard(fake_db, spy):
    from alerts import dispatch
    basis = json.dumps({"reason": "침수심 230mm", "simulated": True})
    fake_db.rows["FROM risk_assessments WHERE valid_to IS NULL AND level >= 'advisory'"] = [
        {"id": 11, "hazard": "flood", "level": "advisory", "label": "침수 주의", "basis": basis},
        {"id": 12, "hazard": "flood", "level": "warning", "label": "침수 경보", "basis": basis},
        {"id": 13, "hazard": "uv", "level": "advisory", "label": "자외선 높음", "basis": "{}"},
        {"id": 14, "hazard": "uv", "level": "watch", "label": "자외선 보통", "basis": "{}"},       # 경고 안 함
    ]
    fake_db.rows["WITH a AS (SELECT area FROM risk_assessments"] = [_target(UID)]
    fake_db.rows["INSERT INTO user_alerts"] = [{"id": ALERT}]
    fake_db.rows["INSERT INTO care.incidents (hazard, level, title, area, assessment_id, source)"] = [{"id": INCIDENT}]
    assert dispatch.run() == 2                                         # 침수 경보(대피 확인) + 자외선 주의
    inserts = [p for sql, p in spy if "INSERT INTO user_alerts" in sql]
    assert {(p["hazard"], p["level"], p["key"], p["rr"]) for p in inserts} == {
        ("flood", "warning", "ra:12", True), ("uv", "advisory", "ra:13", False)}
    flood = next(p for p in inserts if p["hazard"] == "flood")
    assert flood["iid"] == INCIDENT and flood["tts"]
    inc = next(p for sql, p in spy if "INSERT INTO care.incidents (hazard" in sql)
    assert inc["aid"] == 12 and inc["source"] == "simulated"
    assert any("INSERT INTO care.incident_targets (incident_id, user_id" in sql for sql, _ in fake_db.executed)


def test_dispatch_same_level_prefers_nearest_station(fake_db, spy):
    from alerts import dispatch
    far = json.dumps({"station_lat": 35.9893, "station_lng": 129.5571})        # 수협 맨홀
    near = json.dumps({"station_lat": 35.99069, "station_lng": 129.556057})    # 환승센터
    fake_db.rows["FROM risk_assessments WHERE valid_to IS NULL AND level >= 'advisory'"] = [
        {"id": 5, "hazard": "flood", "level": "warning", "label": "침수 경보", "basis": far},
        {"id": 9, "hazard": "flood", "level": "warning", "label": "침수 경보", "basis": near}]
    fake_db.rows["WITH a AS (SELECT area FROM risk_assessments"] = [_target(UID, lat=35.99069, lng=129.556057)]
    fake_db.rows["INSERT INTO user_alerts"] = [{"id": ALERT}]
    fake_db.rows["INSERT INTO care.incidents (hazard, level, title, area, assessment_id, source)"] = [{"id": INCIDENT}]
    assert dispatch.run() == 1
    assert [p["key"] for sql, p in spy if "INSERT INTO user_alerts" in sql] == ["ra:9"]


@pytest.mark.parametrize("flood,rain,keys", [
    ("warning", "warning", ["ra:1"]),               # 같은 단계 → 침수 1건 (호우는 문구에 함께)
    ("advisory", "critical", ["ra:2"]),             # 호우가 더 높음 → 호우 1건
    ("advisory", "advisory", ["ra:1", "ra:2"]),     # 둘 다 일반 경고 → 묶지 않음
])
def test_dispatch_merges_flood_and_heavy_rain(fake_db, spy, flood, rain, keys):
    from alerts import dispatch
    fake_db.rows["FROM risk_assessments WHERE valid_to IS NULL AND level >= 'advisory'"] = [
        {"id": 1, "hazard": "flood", "level": flood, "label": "침수", "basis": "{}"},
        {"id": 2, "hazard": "heavy_rain", "level": rain, "label": "강우", "basis": "{}"}]
    fake_db.rows["WITH a AS (SELECT area FROM risk_assessments"] = [_target(UID)]
    fake_db.rows["INSERT INTO user_alerts"] = [{"id": ALERT}]
    fake_db.rows["INSERT INTO care.incidents (hazard, level, title, area, assessment_id, source)"] = [{"id": INCIDENT}]
    dispatch.run()
    ins = [p for sql, p in spy if "INSERT INTO user_alerts" in sql]
    assert sorted(p["key"] for p in ins) == keys
    if len(keys) == 1:
        other = "호우" if keys == ["ra:1"] else "침수"
        assert f"{other} " in ins[0]["body"] and "함께 발효 중" in ins[0]["body"] and "함께 발효 중" in ins[0]["tts"]


def test_dispatch_existing_alert_not_duplicated(fake_db):
    from alerts import dispatch
    fake_db.rows["FROM risk_assessments WHERE valid_to IS NULL AND level >= 'advisory'"] = [
        {"id": 12, "hazard": "flood", "level": "warning", "label": "침수 경보", "basis": "{}"}]
    fake_db.rows["WITH a AS (SELECT area FROM risk_assessments"] = [_target(UID)]
    fake_db.rows["INSERT INTO care.incidents (hazard, level, title, area, assessment_id, source)"] = [{"id": INCIDENT}]
    # INSERT INTO user_alerts → ON CONFLICT DO NOTHING → 행 없음
    assert dispatch.run() == 0
    assert not any("INSERT INTO care.incident_targets (incident_id, user_id" in sql for sql, _ in fake_db.executed)


def test_dispatch_disaster_message_broadcast(fake_db, spy):
    from alerts import dispatch
    fake_db.rows["FROM disaster_messages\nWHERE sent_at"] = [
        {"external_id": "777", "category": "호우", "hazard": None,
         "message": "[포항시] 구룡포읍 저지대 주민은 대피소로 대피하시기 바랍니다"},
        {"external_id": "778", "category": "호우", "hazard": None, "message": "[포항시] 흥해읍 대피소로 대피"}]
    fake_db.rows["INSERT INTO care.incidents (hazard, level, title, area, source, note)"] = [{"id": INCIDENT}]
    fake_db.rows["JOIN disaster_messages m ON i.note"] = [
        {"id": INCIDENT, "hazard": "heavy_rain", "level": "warning", "external_id": "777", "message": "구룡포 대피"}]
    fake_db.rows["WITH a AS (SELECT area FROM care.incidents"] = [_target(UID, trigger="place", place_label="우리집")]
    fake_db.rows["INSERT INTO user_alerts"] = [{"id": ALERT}]
    assert dispatch.run() == 1
    msg_inc = [p for sql, p in spy if "source, note)" in sql]
    assert [p["note"] for p in msg_inc] == ["disaster_message:777"]
    ins = next(p for sql, p in spy if "INSERT INTO user_alerts" in sql)
    assert ins["key"] == "msg:777" and ins["rr"] and ins["aid"] is None and ins["pid"] is None
    assert json.loads(ins["reason"])["trigger"] == "broadcast"


# ------------------------------------------------------------------ 사용자 API
USER_ROW = {"id": UID, "firebase_uid": "test-uid", "is_anonymous": True, "role": "resident", "created_at": NOW,
            "nickname": "하린", "user_type": "resident", "birth_year": 1958, "mobility": "walk", "occupation": "fisher",
            "owns_vessel": True, "walking_ability": "limited", "vision_impaired": True, "hearing_impaired": False,
            "blood_type": None, "has_dependents": False, "dependents_note": None, "medical_note": None,
            "prefers_voice": False, "language": "ko", "alert_prefs": {}, "has_profile": True}


def _user_rows(fake_db, created=True):
    fake_db.rows["INSERT INTO users (firebase_uid, is_anonymous, last_active_at)"] = [{"id": UID, "created": created}]
    fake_db.rows["SELECT id FROM users WHERE firebase_uid"] = [{"id": UID}]
    fake_db.rows["FROM users u LEFT JOIN user_profiles"] = [USER_ROW]
    fake_db.rows["FROM user_places pl"] = [{"id": "7b1f6a3e-2c4d-4e8f-9a01-3b5c7d9e1f20", "place_type": "home",
                                            "label": "우리집", "address": "경북 포항시 남구 구룡포읍 호미로 152", "notify": True, "lat": 35.9862,
                                            "lng": 129.5489, "in_hazard_zones": ["landslide"]}]


def test_user_requires_registration(client):
    r = client.get("/api/v1/user", headers=AUTH)
    assert r.status_code == 404 and r.json()["code"] == "NOT_FOUND"


def test_user_register_and_get(client, fake_db):
    _user_rows(fake_db)
    r = client.post("/api/v1/user", headers=AUTH, json={"birth_year": 1958})
    assert r.status_code == 201 and "X-Mock" not in r.headers
    assert any("INSERT INTO user_profiles" in sql for sql, _ in fake_db.executed)
    d = client.get("/api/v1/user", headers=AUTH).json()
    assert_spec(d, "/user")
    assert d["firebase_uid"] == "test-uid" and d["places"][0]["in_hazard_zones"] == ["landslide"]
    assert d["profile"]["alert_prefs"]["tts"] is True                  # 시각장애 → 음성 기본값
    assert d["onboarding"] == {"completed": True, "missing": []}
    _user_rows(fake_db, created=False)
    assert client.post("/api/v1/user", headers=AUTH, json={}).status_code == 200    # 이미 있음


def test_app_state(client, fake_db):
    _user_rows(fake_db)
    r = client.put("/api/v1/user/app-state", headers=AUTH, json={"state": {"version": 1, "prefs": {"profile_age": "67"}}})
    assert r.status_code == 204
    assert any("app_state" in sql for sql, _ in fake_db.executed)
    assert client.put("/api/v1/user/app-state", headers=AUTH, json={"state": {"x": "a" * 70000}}).status_code == 422
    assert client.put("/api/v1/user/app-state", headers=AUTH, json={}).status_code == 422


def test_place_add(client, fake_db, monkeypatch):
    _user_rows(fake_db)
    fake_db.rows["INSERT INTO user_places"] = [{"id": "7b1f6a3e-2c4d-4e8f-9a01-3b5c7d9e1f20"}]
    ran = []
    from alerts import dispatch
    from app.routers import user
    monkeypatch.setattr(dispatch, "run", lambda run_id=None, user_id=None: ran.append(user_id) or 0)
    # 장소는 도로명 주소로 받고 서버가 좌표로 바꾼다 (카카오, 2026-10-04 C 변경) — 테스트는 변환을 흉내
    monkeypatch.setattr(user, "geocode_road_address",
                        lambda a: {"address": "경북 포항시 남구 구룡포읍 호미로 152", "location": {"lat": 35.9862, "lng": 129.5489}})
    r = client.post("/api/v1/user/places", headers=AUTH,
                    json={"place_type": "home", "label": "우리집", "address": "구룡포읍 호미로 152"})
    assert r.status_code == 201 and r.json()["label"] == "우리집"
    assert ran == [UID]                                                # 등록한 장소로 즉시 경고 판정


def test_device_token(client, fake_db):
    _user_rows(fake_db)
    fake_db.rows["INSERT INTO user_devices (user_id, platform, fcm_token)"] = [{"id": "11111111-2222-4333-8444-555555555555"}]
    r = client.post("/api/v1/device-token", headers=AUTH, json={"token": "fcm-abc", "platform": "android"})
    assert r.json() == {"device_id": "11111111-2222-4333-8444-555555555555"}
    assert client.post("/api/v1/device-token", headers=AUTH, json={"token": "x", "platform": "pc"}).status_code == 422


# ------------------------------------------------------------------ 경고 API
ALERT_ROW = {"id": ALERT, "hazard": "flood", "level": "warning", "title": "[대피 확인] 침수 경보 · 현재 위치",
             "body": "…", "reason": {"trigger": "current_location", "place_label": None, "profile_tags": []},
             "actions": [{"type": "respond", "label": "대피 확인", "params": {"buttons": ["evacuated", "evacuating", "need_help"]}}],
             "created_at": NOW, "read_at": None, "response_required": True, "incident_id": INCIDENT, "tts_text": "침수 경보입니다.",
             "lat": 35.99, "lng": 129.556, "ra_id": 12, "ra_label": "침수 경보 (포항 DT 4단계)", "rule_id": 23,
             "basis": {"reason": "침수심 230mm", "station_lat": 35.99, "station_lng": 129.556, "observed_at": NOW.isoformat(),
                       "simulated": True},
             "my_status": "no_response"}
MSG_ROW = {**ALERT_ROW, "id": "b2c3d4e5-f6a7-4b8c-9d0e-1f2a3b4c5d6e", "hazard": "heavy_rain", "ra_id": None,
           "ra_label": None, "rule_id": None, "basis": None, "my_status": "evacuating"}


def test_alerts_poll(client, fake_db, monkeypatch):
    _user_rows(fake_db)
    fake_db.rows["FROM user_alerts a\n  LEFT JOIN risk_assessments"] = [ALERT_ROW, MSG_ROW]
    fake_db.rows["FROM care.incident_targets t JOIN care.incidents i"] = [
        {"incident_id": INCIDENT, "alert_id": ALERT, "hazard": "flood", "level": "warning", "title": "침수 경보",
         "status": "no_response", "status_at": None, "started_at": NOW}]
    ran = []
    from alerts import dispatch
    monkeypatch.setattr(dispatch, "run", lambda run_id=None, user_id=None: ran.append(user_id) or 0)
    d = client.get("/api/v1/alerts", headers=AUTH, params={"lat": 35.99, "lng": 129.556}).json()
    assert_spec(d, "/alerts")
    assert ran == [UID]                                                # 위치를 보내면 그 사용자만 즉시 판정
    assert any("UPDATE user_devices SET last_location" in sql for sql, _ in fake_db.executed)
    a, m = d["alerts"]
    assert a["risk"]["area_id"] == 12 and a["risk"]["simulated"] and a["my_status"] is None
    assert m["risk"]["label"] == "호우 경보" and m["my_status"] == "evacuating"
    assert d["mode"] == "emergency" and d["next_poll_sec"] == 15 and d["evacuation"]["alert_id"] == ALERT
    ran.clear()
    d = client.get("/api/v1/alerts", headers=AUTH).json()              # 위치 없이 → 즉시 판정 안 함
    assert ran == []


def test_alerts_poll_normal(client, fake_db):
    _user_rows(fake_db)
    d = client.get("/api/v1/alerts", headers=AUTH, params={"since": NOW.isoformat()}).json()
    assert d["alerts"] == [] and d["mode"] == "normal" and d["evacuation"] is None and d["next_poll_sec"] == 60


def test_alert_read(client, fake_db):
    assert client.post(f"/api/v1/alerts/{ALERT}/read", headers=AUTH).status_code == 204     # FakeDB execute = 1
    # 대피 확인 응답(/response)은 tests/test_evacuation.py


# ------------------------------------------------------------------ 장소: 주소·좌표 둘 다 받음 (2026-10-04)
def _place_rows(fake_db, address="경북 포항시 남구 구룡포읍 호미로 152"):
    _user_rows(fake_db)
    fake_db.rows["INSERT INTO user_places"] = [{"id": "7b1f6a3e-2c4d-4e8f-9a01-3b5c7d9e1f20"}]
    fake_db.rows["FROM user_places pl"] = [{"id": "7b1f6a3e-2c4d-4e8f-9a01-3b5c7d9e1f20", "place_type": "home",
                                            "label": "우리집", "address": address, "notify": True,
                                            "lat": 35.9862, "lng": 129.5489, "in_hazard_zones": []}]


def _spy_geocoder(monkeypatch):
    from app.routers import user
    calls = []
    monkeypatch.setattr(user, "geocode_road_address", lambda a: calls.append(a) or
                        {"address": "경북 포항시 남구 구룡포읍 호미로 152", "location": {"lat": 35.9862, "lng": 129.5489}})
    return calls


def _insert_params(fake_db, monkeypatch):
    from app import db
    seen = []
    orig = db.fetch_one
    monkeypatch.setattr(db, "fetch_one", lambda sql, p=None: seen.append((sql, p)) or orig(sql, p))
    return seen


def test_place_with_location_skips_geocoder(client, fake_db, monkeypatch):
    """좌표가 있으면 카카오를 부르지 않는다 — 카카오 키 없이도 등록 (지번 주소·항구·GPS)"""
    _place_rows(fake_db, address=None)
    calls, seen = _spy_geocoder(monkeypatch), _insert_params(fake_db, monkeypatch)
    r = client.post("/api/v1/user/places", headers=AUTH,
                    json={"place_type": "work", "label": "구룡포항 3부두", "location": {"lat": 35.9893, "lng": 129.5571}})
    assert r.status_code == 201 and calls == []
    assert_spec(r.json(), "/user/places", "post", "201")
    ins = next(p for sql, p in seen if "INSERT INTO user_places" in sql)
    assert (ins["lat"], ins["lng"], ins["address"]) == (35.9893, 129.5571, None)
    # 주소 + 좌표 → 좌표 그대로, 주소는 받은 글자 그대로
    client.post("/api/v1/user/places", headers=AUTH, json={"place_type": "home", "label": "집", "address": "구룡포읍 병포리 123",
                                                           "location": {"lat": 35.98, "lng": 129.55}})
    ins = [p for sql, p in seen if "INSERT INTO user_places" in sql][-1]
    assert calls == [] and (ins["address"], ins["lat"]) == ("구룡포읍 병포리 123", 35.98)


def test_place_address_only_uses_geocoder(client, fake_db, monkeypatch):
    _place_rows(fake_db)
    calls = _spy_geocoder(monkeypatch)
    assert client.post("/api/v1/user/places", headers=AUTH,
                       json={"place_type": "home", "label": "집", "address": "구룡포읍 호미로 152"}).status_code == 201
    assert calls == ["구룡포읍 호미로 152"]
    assert client.post("/api/v1/user/places", headers=AUTH,
                       json={"place_type": "home", "label": "집"}).status_code == 422             # 둘 다 없음


def test_place_patch_location_keeps_address(client, fake_db, monkeypatch):
    _place_rows(fake_db)
    calls = _spy_geocoder(monkeypatch)
    pid = "7b1f6a3e-2c4d-4e8f-9a01-3b5c7d9e1f20"
    client.patch(f"/api/v1/user/places/{pid}", headers=AUTH, json={"location": {"lat": 35.97, "lng": 129.56}})
    upd = next(p for sql, p in fake_db.executed if "UPDATE user_places SET" in sql)
    assert calls == [] and upd["lat"] == 35.97 and "address" not in upd


def test_lodging_counts_as_home_for_onboarding(client, fake_db):
    """숙소만 등록한 관광객은 집 등록을 요구하지 않는다"""
    _user_rows(fake_db)
    fake_db.rows["FROM users u LEFT JOIN user_profiles"] = [{**USER_ROW, "user_type": None}]
    fake_db.rows["FROM user_places pl"] = [{"id": "7b1f6a3e-2c4d-4e8f-9a01-3b5c7d9e1f20", "place_type": "lodging",
                                            "label": "구룡포 게스트하우스", "address": None, "notify": True,
                                            "lat": 35.99, "lng": 129.55, "in_hazard_zones": []}]
    assert client.get("/api/v1/user", headers=AUTH).json()["onboarding"] == {"completed": True, "missing": []}
    fake_db.rows["FROM user_places pl"] = []
    assert client.get("/api/v1/user", headers=AUTH).json()["onboarding"]["missing"] == ["home_place"]


def test_fisher_among_several_jobs():
    """앱은 직업 여러 개를 'fisher, other' 로 보낸다 (2026-10-08) — 그중 어업이 있으면 어업 맞춤"""
    from alerts.messages import profile_tags
    assert "fisher" in profile_tags({"occupation": "fisher, other"})
    assert "fisher" not in profile_tags({"occupation": "office, 수산업자"})
