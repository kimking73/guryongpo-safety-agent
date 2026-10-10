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


def test_validation_error_format(client):
    r = client.get("/api/v1/dashboard", headers=AUTH)            # lat/lng 누락
    assert r.status_code == 422 and r.json()["code"] == "VALIDATION_ERROR"
    r = client.patch("/api/v1/user", headers=AUTH, json={"blood_type": "Z"})
    assert r.status_code == 422


def test_dashboard_empty_db_is_normal_and_says_no_data(client):
    """실데이터 대시보드 (2026-10-05): 자료가 없으면 지어내지 않고 available=false + 사유"""
    from test_alerts import assert_spec
    r = client.get("/api/v1/dashboard?lat=35.98&lng=129.55", headers=AUTH)
    d = r.json()
    assert r.status_code == 200 and "X-Mock" not in r.headers
    assert_spec(d, "/dashboard")
    assert d["mode"] == "normal" and d["headline"] is None
    w = {x["type"]: x["data"] for x in d["widgets"]}
    assert w["warnings"] == {"items": []}
    for t in ("rain", "wind", "water_level", "wave", "forecast", "disaster_messages", "life_safety"):
        assert w[t]["available"] is False and w[t]["reason"], t
    assert "typhoon" not in w                      # 진행 중인 태풍이 없으면 카드 자체를 숨김


def _typhoon_row(code, lat, lng, t, is_forecast=False):
    return {"typhoon_code": code, "name_ko": code, "observed_at": t, "is_forecast": is_forecast, "lat": lat, "lng": lng,
            "max_wind_ms": 30, "central_pressure_hpa": 970, "radius_15ms_km": 300, "radius_25ms_km": 100,
            "speed_kmh": 20, "direction": "N", "location_text": None}


def test_dashboard_hides_typhoon_far_from_guryongpo(client, fake_db):
    """예측 최근접도 1000km 밖인 태풍(예: 4735km · 최근접 1778km)은 구룡포와 무관 → 카드 숨김"""
    from datetime import timedelta
    now = datetime.now(KST)
    fake_db.rows["FROM typhoon_tracks t JOIN cur"] = [
        _typhoon_row("FAR", 0.0, 160.0, now), _typhoon_row("FAR", 15.0, 140.0, now + timedelta(days=3), True)]
    w = {x["type"]: x["data"] for x in client.get("/api/v1/dashboard?lat=35.98&lng=129.55", headers=AUTH).json()["widgets"]}
    assert "typhoon" not in w


def test_dashboard_shows_nearest_relevant_typhoon(client, fake_db):
    from datetime import timedelta
    now = datetime.now(KST)
    fake_db.rows["FROM typhoon_tracks t JOIN cur"] = [
        _typhoon_row("FAR", 0.0, 160.0, now),
        _typhoon_row("NEAR", 28.0, 127.0, now), _typhoon_row("NEAR", 35.0, 129.0, now + timedelta(days=1), True)]
    w = {x["type"]: x["data"] for x in client.get("/api/v1/dashboard?lat=35.98&lng=129.55", headers=AUTH).json()["widgets"]}
    assert w["typhoon"]["code"] == "NEAR" and w["typhoon"]["closest_km"] < 150


def test_dashboard_real_values_and_emergency_order(client, fake_db):
    from datetime import timedelta
    from test_alerts import assert_spec
    now = datetime.now(KST)
    fake_db.rows["FROM shelters s"] = [
        {"id": 1, "name": "구룡포초등학교", "shelter_types": ["earthquake"], "address": "구룡포읍", "capacity": 300, "phone": None,
         "is_indoor": False, "is_accessible": True, "lng": 129.552, "lat": 35.986, "in_risk_area": False, "landslide_zone_m": None, "landslide_zone_name": None},
        {"id": 2, "name": "침수된 대피소", "shelter_types": [], "address": None, "capacity": None, "phone": None,
         "is_indoor": False, "is_accessible": None, "lng": 129.556, "lat": 35.990, "in_risk_area": True, "landslide_zone_m": None, "landslide_zone_name": None}]
    fake_db.rows["FROM risk_assessments ra, (SELECT"] = [{
        "id": 7, "hazard": "heavy_rain", "level": "warning", "label": "호우경보", "rule_id": 2, "computed_at": now,
        "distance_m": 0, "source_distance_m": 0,
        "basis": {"reason": "3시간 누적강수 92.0mm (구룡포 AWS)", "station_lat": 35.99, "station_lng": 129.55, "observed_at": now.isoformat()}}]
    fake_db.rows["FROM weather_warnings"] = [{"hazard": "heavy_rain", "level": "warning", "region_name": "포항시",
                                              "issued_at": now, "effective_at": now, "headline": "포항시 호우경보"}]
    fake_db.rows["AND o.metric = ANY(%(metrics)s)"] = [
        {"metric": "rain_1h", "value": 31.5, "unit": "mm", "observed_at": now - timedelta(minutes=10)},
        {"metric": "rain_day", "value": 120.0, "unit": "mm", "observed_at": now - timedelta(minutes=10)}]
    fake_db.rows["FROM typhoon_tracks t JOIN cur"] = [
        {"typhoon_code": "2627", "name_ko": "초이완", "observed_at": now - timedelta(hours=3), "is_forecast": False,
         "lat": 33.0, "lng": 128.0, "max_wind_ms": 35, "central_pressure_hpa": 960, "radius_15ms_km": 300, "location_text": "제주 남쪽 해상"},
        {"typhoon_code": "2627", "name_ko": "초이완", "observed_at": now + timedelta(hours=21), "is_forecast": True,
         "lat": 35.9, "lng": 129.7, "max_wind_ms": 30, "central_pressure_hpa": 975, "radius_15ms_km": 250, "location_text": None}]
    d = client.get("/api/v1/dashboard?lat=35.985&lng=129.55", headers=AUTH).json()
    assert_spec(d, "/dashboard")
    assert d["mode"] == "emergency" and d["headline"]["action"] == "open_route"
    assert [s["name"] for s in d["nearest_shelters"]] == ["구룡포초등학교"]          # 위험 영역 안 대피소 제외
    w = {x["type"]: x for x in d["widgets"]}
    assert d["widgets"][0]["type"] == "warnings" and w["rain"]["emphasized"]
    assert w["rain"]["data"]["value"] == 31.5 and w["rain"]["data"]["rain_day"] == 120.0 and w["rain"]["data"]["level"] == "warning"
    t = w["typhoon"]["data"]
    assert t["name_ko"] == "초이완" and t["closest_km"] < t["distance_km"] and len(t["track"]) == 2


def test_support_programs(client, fake_db):
    fake_db.rows["FROM support_programs"] = [{
        "id": 1, "category": "recovery", "hazards": ["flood"], "targets": ["all"], "name": "재난지원금", "summary": "주택 침수 지원",
        "eligibility": None, "how_to_apply": "읍사무소", "apply_period": None, "department": "포항시", "contact": None, "url": None,
        "updated_at": datetime.now(KST)}]
    r = client.get("/api/v1/support-programs?hazard=flood")
    assert r.status_code == 200 and r.json()[0]["name"] == "재난지원금"
    assert client.get("/api/v1/support-programs?hazard=nope").status_code == 422


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


def test_flood_grid_exposes_only_assessed_cells_with_source_and_depth(client, fake_db):
    fake_db.rows["WITH env AS"] = [{
        "cell_id": "129550_35980", "id": 21, "level": "warning", "label": "침수 위험",
        "basis": {"metric": "flood_depth", "value": 230, "unit": "mm", "observed_at": "2026-10-05T14:27:00+09:00", "station_name": "구룡포 수위계"},
        "geojson": '{"type":"Polygon","coordinates":[[[129.55,35.98],[129.554,35.98],[129.554,35.984],[129.55,35.984],[129.55,35.98]]]}',
    }]
    response = client.get("/api/v1/dashboard/layers/flood_grid")
    assert response.status_code == 200
    feature = response.json()["features"][0]
    assert feature["properties"]["level"] == "warning"
    assert feature["properties"]["observed_depth_cm"] == 23
    assert feature["properties"]["source"] == "구룡포 수위계"
    assert feature["properties"]["data_status"] == "assessed"
    assert feature["id"] == "129550_35980" and feature["properties"]["area_id"] == 21


def test_flood_grid_uses_same_rule_as_route_server():
    """침수 격자 = 경로 서버가 피하는 침수 영역 (주의 이상, 지금 유효한 판정만) — 두 기준이 어긋나면 지도와 경로가 달라진다"""
    import pathlib, re
    from app import layers
    hz = (pathlib.Path(__file__).resolve().parents[2] / "route" / "guardian_route" / "hazards.py").read_text(encoding="utf-8")
    assert re.search(r'MIN_LEVEL = "(\w+)"', hz).group(1) == layers.FLOOD_GRID_MIN_LEVEL
    assert "valid_to IS NULL" in layers.FLOOD_GRID_SQL and "ra.hazard = 'flood'" in layers.FLOOD_GRID_SQL


def test_flood_grid_is_empty_when_no_assessments(client):
    response = client.get("/api/v1/dashboard/layers/flood_grid")
    assert response.status_code == 200 and response.json()["features"] == []


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


def test_chat_route_voice_removed_from_api(client):
    """대화·경로·음성은 ai·route 서비스 — api 에는 없음 (v0.2 목업 삭제)"""
    for path in ("/api/v1/chat", "/api/v1/route", "/api/v1/route/check", "/api/v1/voice"):
        assert client.post(path, headers=AUTH, json={}).status_code == 404


def test_shelter_unsuitable_for_landslide(client, fake_db):
    fake_db.rows["FROM shelters s"] = [
        {"id": 3, "name": "충혼탑 앞", "shelter_types": ["tsunami"], "address": None, "capacity": None, "phone": None,
         "is_indoor": False, "is_accessible": None, "lng": 129.55, "lat": 35.99, "in_risk_area": False, "landslide_zone_m": 35, "landslide_zone_name": "구룡포읍 삼정리 산126-2임"},
        {"id": 4, "name": "구룡포항 앞", "shelter_types": ["tsunami"], "address": None, "capacity": None, "phone": None,
         "is_indoor": False, "is_accessible": None, "lng": 129.56, "lat": 35.99, "in_risk_area": False, "landslide_zone_m": None, "landslide_zone_name": None}]
    f = client.get("/api/v1/dashboard/layers/shelters").json()["features"]
    assert f[0]["properties"]["unsuitable_for"] == ["landslide"]
    assert f[0]["properties"]["unsuitable_reason"] == "산사태 취약지역 구룡포읍 삼정리 산126-2임 35m"
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
    # 시연 코드도 users.role 에 저장한다 (저장 안 하면 GET /user 가 resident 라 앱 방재단 화면이 안 열림)
    fake_db.rows["::user_role, now())"] = [{"role": "responder", "granted_at": datetime.now(KST)}]
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
    fake_db.rows["INSERT INTO users (firebase_uid"] = [{"id": "11111111-2222-4333-8444-555555555555", "created": False}]
    assert client.get("/api/v1/admin/overview", headers=AUTH).status_code == 200     # DB 역할로도 통과
    fake_db.rows.clear()
    fake_db.fail = True                                                # DB 장애 → 권한 없음 (안전 쪽)
    assert client.get("/api/v1/admin/overview", headers=AUTH).status_code == 403


def test_demo_endpoints_shape_and_no_writes(client, fake_db):
    """시연 모드 API: 실측 /dashboard 와 같은 모양, 판정·관측 테이블에는 쓰지 않는다"""
    from test_alerts import assert_spec
    from risk import demo
    demo._cache.clear()
    fake_db.rows["FROM stations WHERE is_active"] = [
        {"id": 10, "source_code": "pohang_dt", "external_id": "10", "name": "구룡포환승센터_지표면 수위계", "kind": "road_flood",
         "is_mountain": False, "lng": 129.5559, "lat": 35.9906},
        {"id": 44, "source_code": "kma", "external_id": "aws_816", "name": "구룡포 AWS", "kind": "weather",
         "is_mountain": False, "lng": 129.556, "lat": 35.99}]
    d = client.get("/api/v1/demo/dashboard?lat=35.99&lng=129.55").json()
    assert_spec(d, "/demo/dashboard")
    assert d["mode"] == "emergency" and d["demo"]["scenario"]
    w = {x["type"]: x["data"] for x in d["widgets"]}
    assert w["rain"]["value"] == demo.AWS["rain_1h"] and w["wind"]["wind_gust"] == demo.AWS["wind_gust"]
    assert any("[시연]" in i["label"] for i in w["warnings"]["items"])
    assert client.get("/api/v1/demo/risk/areas?min_level=advisory").status_code == 200
    assert client.get("/api/v1/demo/layers/stations").status_code == 200
    assert client.get("/api/v1/demo/layers/flood_grid").status_code == 200
    assert client.get("/api/v1/demo/layers/manholes").status_code == 422
    assert not any(("risk_assessments" in sql or "observations" in sql) and sql.lstrip().upper().startswith(("INSERT", "UPDATE", "DELETE"))
                   for sql, _ in fake_db.executed)
