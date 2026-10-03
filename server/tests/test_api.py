"""API 골격 — 라우팅·인증·에러 형식·목업 응답 (v0.3: 역할·가구·대피 확인·방재단 포함)"""
from datetime import datetime, timedelta, timezone

from conftest import AUTH

KST = timezone(timedelta(hours=9))


def test_health_ok(client, fake_db):
    now = datetime.now(KST)
    from collector.jobs import JOBS
    fake_db.rows["FROM ingest_runs"] = [
        {"source_code": j.source, "job": j.job, "last_success_at": now, "last_status": "success"} for j in JOBS]
    for path in ("/api/v1/health", "/api/health"):
        r = client.get(path)
        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "ok"
        assert body["components"]["db"]["status"] == "ok"
        assert body["components"]["ingest.pohang_dt"]["status"] == "ok"


def test_health_degraded_when_ingest_stale(client, fake_db):
    old = datetime.now(KST) - timedelta(hours=2)
    fake_db.rows["FROM ingest_runs"] = [
        {"source_code": "pohang_dt", "job": "water_level", "last_success_at": old, "last_status": "failed"}]
    body = client.get("/api/v1/health").json()
    assert body["status"] == "degraded"
    assert body["components"]["ingest.pohang_dt"]["status"] in ("degraded", "down")
    assert "water_level" in body["components"]["ingest.pohang_dt"]["stale_jobs"]


def test_health_down_when_db_down(client, fake_db):
    fake_db.fail = True
    r = client.get("/api/v1/health")
    assert r.status_code == 503 and r.json()["components"]["db"]["status"] == "down"


def test_auth_required(client):
    r = client.get("/api/v1/user")
    assert r.status_code == 401
    assert r.json()["code"] == "UNAUTHORIZED" and r.json()["message"]
    assert client.get("/api/v1/user", headers={"Authorization": "Basic abc"}).status_code == 401


def test_user_mock_uses_caller_uid(client):
    r = client.get("/api/v1/user", headers=AUTH)
    assert r.status_code == 200 and r.headers["X-Mock"] == "true"
    assert r.json()["firebase_uid"] == "test-uid"
    assert client.post("/api/v1/user", headers=AUTH, json={}).status_code == 201


def test_validation_error_format(client):
    r = client.get("/api/v1/dashboard", headers=AUTH)            # lat/lng 누락
    assert r.status_code == 422 and r.json()["code"] == "VALIDATION_ERROR"
    r = client.patch("/api/v1/user", headers=AUTH, json={"blood_type": "Z"})
    assert r.status_code == 422


def test_dashboard_modes(client):
    q = "/api/v1/dashboard?lat=35.98&lng=129.55"
    assert client.get(q, headers=AUTH).json()["mode"] == "normal"
    assert client.get(q + "&scenario=emergency", headers=AUTH).json()["mode"] == "emergency"


def test_layers(client, fake_db):
    fake_db.rows["FROM stations s"] = [{
        "id": 10, "source_code": "pohang_dt", "external_id": "10", "name": "구룡포환승센터_지표면 수위계",
        "kind": "road_flood", "lng": 129.556, "lat": 35.990, "metric": "flood_depth", "value": 230.0, "unit": "mm",
        "source_level": 4, "observed_at": datetime.now(KST)}]
    r = client.get("/api/v1/dashboard/layers/stations")
    f = r.json()["features"][0]
    assert f["geometry"]["coordinates"] == [129.556, 35.990]       # GeoJSON 은 [경도, 위도]
    assert f["properties"]["level"] == "warning" and f["properties"]["source_level_label"] == "경보"
    assert client.get("/api/v1/dashboard/layers/flood_zones").status_code == 404           # 침수·해안 고정 영역 레이어 없음 (산사태만)
    assert client.get("/api/v1/dashboard/layers/nope").status_code == 404
    assert client.get("/api/v1/dashboard/layers/stations?bbox=1,2").status_code == 422


def test_static_layers(client, fake_db):
    """A7: 대피소·의료시설·맨홀은 loader 가 적재한 DB 값"""
    fake_db.rows["FROM shelters s"] = [{
        "id": 3, "name": "구룡포 초등학교 앞", "shelter_types": ["tsunami"], "address": "구룡포길65번길 7", "capacity": None,
        "phone": None, "is_indoor": False, "is_accessible": None, "lng": 129.5526, "lat": 35.9912, "in_risk_area": True}]
    fake_db.rows["FROM medical_facilities"] = [{
        "id": 1, "name": "포항성모병원", "kind": "emergency_room", "address": "대잠동길 17", "phone": "054-272-0151",
        "meta": {"er_phone": "054-260-8600", "emergency_class": "권역응급의료센터"}, "lng": 129.34, "lat": 36.016}]
    fake_db.rows["FROM manholes m"] = [{
        "id": 1, "source_code": "pohang_dt", "external_id": "2", "kind": "smart", "lng": 129.549, "lat": 35.986,
        "name": "하나과메기_스마트맨홀"}]
    r = client.get("/api/v1/dashboard/layers/shelters")
    assert "X-Mock" not in r.headers
    p = r.json()["features"][0]["properties"]
    assert p["shelter_types"] == ["tsunami"] and p["in_risk_area"] is True
    m = client.get("/api/v1/dashboard/layers/medical").json()["features"][0]
    assert m["properties"]["er_phone"] == "054-260-8600" and m["geometry"]["coordinates"] == [129.34, 36.016]
    assert client.get("/api/v1/dashboard/layers/manholes").json()["features"][0]["properties"]["kind"] == "smart"


def test_medical_default_bbox_is_pohang(client, monkeypatch):
    """구룡포 안에 응급의료기관이 없음 → bbox 생략 시 포항 전체 범위로 조회"""
    from app import db, layers
    seen = []
    monkeypatch.setattr(db, "fetch_all", lambda sql, params=None: seen.append(params) or [])
    client.get("/api/v1/dashboard/layers/medical")
    client.get("/api/v1/dashboard/layers/medical?bbox=129.5,35.9,129.6,36.0")
    assert [seen[0][k] for k in "abcd"] == list(layers.POHANG_BBOX)
    assert seen[1]["a"] == 129.5


def test_device_token_stable(client):
    body = {"token": "fcm-abc", "platform": "android"}
    a = client.post("/api/v1/device-token", headers=AUTH, json=body).json()["device_id"]
    b = client.post("/api/v1/device-token", headers=AUTH, json=body).json()["device_id"]
    assert a == b
    assert client.post("/api/v1/device-token", headers=AUTH, json={"token": "x", "platform": "pc"}).status_code == 422


def test_alerts_since(client):
    first = client.get("/api/v1/alerts", headers=AUTH).json()
    assert first["alerts"] and first["next_poll_sec"]
    again = client.get("/api/v1/alerts", headers=AUTH, params={"since": first["server_time"]}).json()
    assert again["alerts"] == []


def test_risk_rules_from_db(client, fake_db):
    fake_db.rows["FROM risk_rules"] = [{"id": 9, "hazard": "flood", "level": "advisory", "label": "침수",
                                        "metric": "flood_depth", "operator": ">=", "threshold": 150, "threshold_max": None,
                                        "duration_min": None, "condition": {}, "source_name": "x", "source_url": None}]
    assert client.get("/api/v1/risk/rules").json()[0]["id"] == 9


def test_internal_ingest(client, fake_db, monkeypatch):
    fake_db.rows["INSERT INTO ingest_runs"] = [{"id": 77}]
    from collector import jobs
    ran = []
    monkeypatch.setattr(jobs, "execute", lambda j, run_id=None: ran.append((j.key, run_id)))
    r = client.post("/api/v1/internal/ingest/pohang_dt/water_level")      # dev 모드 + INTERNAL_TOKEN 없음 → 허용
    assert r.status_code == 202 and r.json() == {"ingest_run_id": 77}
    assert ran == [("pohang_dt.water_level", 77)]
    assert client.post("/api/v1/internal/ingest/nope/x").status_code == 404


# ------------------------------------------------------------------ v0.3
STAFF = {"Authorization": "Bearer dev:responder-1"}
CAREGIVER = {"Authorization": "Bearer dev:caregiver-1"}
EVAC_ALERT = "d1e2f3a4-b5c6-4d7e-8f90-a1b2c3d4e5f6"
INCIDENT = "c0ffee00-1d2e-4f30-9a41-5b6c7d8e9f01"


def test_chat_route_voice_removed_from_api(client):
    """대화·경로·음성은 ai·route 서비스 — api 에는 없음 (v0.2 목업 삭제)"""
    for path in ("/api/v1/chat", "/api/v1/route", "/api/v1/route/check", "/api/v1/voice"):
        assert client.post(path, headers=AUTH, json={}).status_code == 404


def test_shelter_unsuitable_for_landslide(client, fake_db):
    fake_db.rows["FROM shelters s"] = [
        {"id": 3, "name": "충혼탑 앞", "shelter_types": ["tsunami"], "address": None, "capacity": None, "phone": None,
         "is_indoor": False, "is_accessible": None, "lng": 129.55, "lat": 35.99, "in_risk_area": False, "landslide_g1_m": 35},
        {"id": 4, "name": "구룡포항 앞", "shelter_types": ["tsunami"], "address": None, "capacity": None, "phone": None,
         "is_indoor": False, "is_accessible": None, "lng": 129.56, "lat": 35.99, "in_risk_area": False, "landslide_g1_m": None}]
    f = client.get("/api/v1/dashboard/layers/shelters").json()["features"]
    assert f[0]["properties"]["unsuitable_for"] == ["landslide"]
    assert f[0]["properties"]["unsuitable_reason"] == "산사태위험지도 1등급 비탈 35m"
    assert f[1]["properties"]["unsuitable_for"] == [] and f[1]["properties"]["unsuitable_reason"] is None


def test_medical_er_beds(client, fake_db):
    now = datetime.now(KST)
    base = {"kind": "emergency_room", "address": None, "phone": None, "meta": {}, "lng": 129.34, "lat": 36.01}
    fake_db.rows["FROM medical_facilities m"] = [
        {**base, "id": 1, "name": "A병원", "er_beds": 3, "ambulance": True, "er_observed_at": now - timedelta(minutes=5)},
        {**base, "id": 2, "name": "B병원", "er_beds": -1, "ambulance": False, "er_observed_at": now - timedelta(hours=2)},
        {**base, "id": 3, "name": "C병원", "er_beds": None, "ambulance": None, "er_observed_at": None}]
    f = [x["properties"]["er"] for x in client.get("/api/v1/dashboard/layers/medical").json()["features"]]
    assert f[0]["beds"] == 3 and f[0]["stale"] is False
    assert f[1]["beds"] == -1 and f[1]["stale"] is True          # 40분 넘음 → 오래된 자료
    assert f[2] is None


def test_hotlines(client, fake_db):
    fake_db.rows["FROM public_hotlines"] = [{"id": 1, "name": "119 화재·구조·구급", "phone": "119", "scope": "national",
                                             "hazards": [], "targets": ["all"], "priority": 1, "note": None, "source_name": "x"}]
    r = client.get("/api/v1/hotlines", params={"hazard": "flood"})
    assert r.status_code == 200 and r.json()[0]["phone"] == "119"
    assert client.get("/api/v1/hotlines", params={"hazard": "nope"}).status_code == 422


def test_role_claim_demo_and_invalid(client, fake_db):
    r = client.post("/api/v1/user/role", headers=AUTH, json={"invite_code": "demo-responder"})
    assert r.status_code == 200 and r.json()["role"] == "responder"
    r = client.post("/api/v1/user/role", headers=AUTH, json={"invite_code": "GRY-XXXX-YYYY"})   # DB 에 없음
    assert r.status_code == 400 and r.json()["code"] == "INVALID_INVITE"


def test_role_claim_real_code(client, fake_db):
    from app.routers.user import code_hash
    fake_db.rows["WITH c AS"] = [{"role": "caregiver", "label": "생활지원사", "granted_at": datetime.now(KST)}]
    r = client.post("/api/v1/user/role", headers=AUTH, json={"invite_code": " gry-ab12-cd34 "})
    assert r.status_code == 200 and r.json()["role"] == "caregiver" and "X-Mock" not in r.headers
    assert code_hash(" gry-ab12-cd34 ") == code_hash("GRY-AB12-CD34")      # 앞뒤 공백·대소문자 무시


def test_internal_invite(client, fake_db):
    fake_db.rows["INSERT INTO care.invite_codes"] = [{"expires_at": datetime.now(KST) + timedelta(days=60)}]
    r = client.post("/api/v1/internal/invites", json={"role": "responder", "label": "방재단"})
    assert r.status_code == 201
    code = r.json()["code"]
    assert code.startswith("GRY-") and len(code) == 13 and not set(code[4:].replace("-", "")) & set("0O1IL")
    assert client.post("/api/v1/internal/invites", json={"role": "resident"}).status_code == 422


def test_admin_requires_staff_role(client, fake_db):
    r = client.get("/api/v1/admin/overview", headers=AUTH)            # dev:test-uid → DB 에 없음 → resident
    assert r.status_code == 403 and r.json()["code"] == "FORBIDDEN"
    fake_db.rows["FROM users WHERE firebase_uid"] = [{"role": "responder"}]
    assert client.get("/api/v1/admin/overview", headers=AUTH).status_code == 200     # DB 역할로도 통과
    fake_db.rows.clear()
    fake_db.fail = True                                                # DB 장애 → 권한 없음 (안전 쪽)
    assert client.get("/api/v1/admin/overview", headers=AUTH).status_code == 403


def test_admin_incident_flow(client):
    lst = client.get("/api/v1/admin/incidents", headers=STAFF).json()
    assert lst and lst[0]["id"] == INCIDENT
    d = client.get(f"/api/v1/admin/incidents/{INCIDENT}", headers=STAFF).json()
    ranks = [t["priority_rank"] for t in d["targets"]]
    assert ranks == sorted(ranks) and d["targets"][0]["status"] == "need_help" and d["next_poll_sec"] == 10
    assert d["rules"] == {"reminder_interval_min": 2, "escalate_after_min": 10, "evacuating_recheck_min": 10}
    tid = d["targets"][1]["id"]
    t = client.patch(f"/api/v1/admin/incidents/{INCIDENT}/targets/{tid}", headers=STAFF,
                     json={"status": "evacuated", "assigned_to": "me"}).json()
    assert t["status"] == "evacuated" and t["status_via"] == "responder" and t["assigned_to"]["is_me"]
    v = client.post(f"/api/v1/admin/incidents/{INCIDENT}/targets/{tid}/visits", headers=STAFF,
                    json={"result": "transported"})
    assert v.status_code == 201 and v.json()["status_after"] == "evacuated"
    app_user = d["targets"][0]["id"]                                   # 가구 미등록 앱 사용자 → 방문 기록 불가
    assert client.post(f"/api/v1/admin/incidents/{INCIDENT}/targets/{app_user}/visits", headers=STAFF,
                       json={"result": "other"}).status_code == 422
    assert client.get("/api/v1/admin/incidents/00000000-0000-4000-8000-000000000000", headers=STAFF).status_code == 404
    assert client.post(f"/api/v1/admin/incidents/{INCIDENT}/close", headers=CAREGIVER).status_code == 403
    assert client.post(f"/api/v1/admin/incidents/{INCIDENT}/close", headers=STAFF).json()["closed_at"]


def test_admin_households(client):
    hs = client.get("/api/v1/admin/households", headers=STAFF, params={"needs": "living_alone"}).json()
    assert hs and all("living_alone" in h["needs"] for h in hs)
    body = {"label": "삼정리 이OO 댁", "location": {"lat": 35.98, "lng": 129.55}, "needs": ["elderly", "hearing"],
            "consent_method": "written", "consent_by": "본인"}
    r = client.post("/api/v1/admin/households", headers=CAREGIVER, json=body)
    assert r.status_code == 201 and r.json()["source"] == "caregiver"
    assert client.post("/api/v1/admin/households", headers=STAFF,
                       json={**body, "needs": ["unknown"]}).status_code == 422
    assert client.post("/api/v1/admin/households", headers=STAFF,
                       json={k: v for k, v in body.items() if k != "consent_by"}).status_code == 422


def test_alert_evacuation_response(client):
    first = client.get("/api/v1/alerts", headers=AUTH).json()
    evac = [a for a in first["alerts"] if a["response_required"]]
    assert evac and first["evacuation"]["alert_id"] == evac[0]["id"] == EVAC_ALERT
    r = client.post(f"/api/v1/alerts/{EVAC_ALERT}/response", headers=AUTH, json={"status": "evacuating", "via": "button"})
    assert r.status_code == 200 and r.json()["recheck_after_min"] == 10
    r = client.post(f"/api/v1/alerts/{EVAC_ALERT}/response", headers=AUTH, json={"status": "need_help", "via": "voice"})
    assert r.status_code == 422                                        # 도움 요청은 위치 필수
    r = client.post(f"/api/v1/alerts/{EVAC_ALERT}/response", headers=AUTH,
                    json={"status": "need_help", "via": "voice", "location": {"lat": 35.99, "lng": 129.55}})
    assert r.json()["call_suggested"] is True
    assert client.post(f"/api/v1/alerts/{EVAC_ALERT}/response", headers=AUTH,
                       json={"status": "no_response", "via": "button"}).status_code == 422   # 앱이 보낼 수 없는 상태
    other = next(a for a in first["alerts"] if not a["response_required"])["id"]
    assert client.post(f"/api/v1/alerts/{other}/response", headers=AUTH,
                       json={"status": "evacuated", "via": "button"}).status_code == 422
    assert client.post("/api/v1/alerts/00000000-0000-4000-8000-000000000000/response", headers=AUTH,
                       json={"status": "evacuated", "via": "button"}).status_code == 404


def test_my_household_requires_consent(client):
    body = {"location": {"lat": 35.98, "lng": 129.55}, "members": 1, "needs": ["elderly"]}
    assert client.put("/api/v1/user/household", headers=AUTH, json=body).status_code == 422
    assert client.put("/api/v1/user/household", headers=AUTH, json={**body, "consent": False}).status_code == 422
    r = client.put("/api/v1/user/household", headers=AUTH, json={**body, "consent": True})
    assert r.status_code == 200 and r.json()["consent"]["method"] == "app"
    assert client.get("/api/v1/user", headers=AUTH).json()["role"] == "resident"
