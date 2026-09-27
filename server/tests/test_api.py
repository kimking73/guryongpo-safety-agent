"""API 골격 — 라우팅·인증·에러 형식·목업 응답"""
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


def test_chat_and_voice(client):
    r = client.post("/api/v1/chat", headers=AUTH, json={"content": "배 보러 부두에 가도 되나"})
    assert r.status_code == 200 and r.json()["message"]["role"] == "assistant"
    r = client.post("/api/v1/voice", headers=AUTH, files={"audio": ("a.m4a", b"\x00" * 100, "audio/m4a")})
    assert r.status_code == 200 and r.json()["transcript"]
    r = client.post("/api/v1/voice", headers=AUTH, files={"audio": ("a.m4a", b"", "audio/m4a")})
    assert r.status_code == 422 and r.json()["code"] == "STT_FAILED"


def test_route(client):
    assert client.post("/api/v1/route", headers=AUTH, json={"origin": {"lat": 35.98, "lng": 129.55}}).status_code == 200
    assert client.post("/api/v1/route", headers=AUTH, json={}).status_code == 422


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
