"""실제 PostgreSQL+PostGIS 에 적재 (TEST_DATABASE_URL 이 있을 때만)

  docker compose exec db sh -c 'createdb -U "$POSTGRES_USER" guardian_test && for f in /docker-entrypoint-initdb.d/*.sql; do psql -q -U "$POSTGRES_USER" -d guardian_test -f $f; done'
  TEST_DATABASE_URL=postgresql://guardian:guardian-local-only@localhost:5433/guardian_test .venv/bin/python -m pytest -q
"""
import os

import pytest

pytestmark = pytest.mark.skipif(not os.environ.get("TEST_DATABASE_URL"), reason="TEST_DATABASE_URL 없음")


# 장소 등록은 도로명 주소 → 카카오 좌표 변환 (C 변경). 통합 테스트는 외부 호출 없이 주소별 좌표를 정해 둔다
PLACES = {"환승센터": (35.99069, 129.556057), "구룡포 밖": (35.93, 129.50)}


@pytest.fixture(autouse=True)
def fake_geocoder(monkeypatch):
    from app.routers import user
    monkeypatch.setattr(user, "geocode_road_address", lambda a: {"address": a, "location": dict(zip(("lat", "lng"), PLACES[a]))})


@pytest.fixture(scope="module")
def real_db():
    from app import db
    from app.config import settings
    db.init_pool(os.environ["TEST_DATABASE_URL"])
    object.__setattr__(settings, "fetch_mode", "replay")
    yield db
    object.__setattr__(settings, "fetch_mode", "live")
    db.close_pool()


def test_replay_all_jobs(real_db):
    from collector import jobs
    results = [jobs.execute(j) for j in jobs.JOBS]
    assert all(r["status"] == "success" for r in results), results
    n = real_db.fetch_one("SELECT count(*) AS n FROM v_latest_observations")["n"]
    assert n > 100


def test_layers_and_health(real_db):
    from app import health, layers
    fc = layers.stations_layer(layers.GURYONGPO_BBOX)
    assert len(fc["features"]) >= 30
    assert layers.landslide_layer(layers.GURYONGPO_BBOX)["features"]      # PostGIS ST_AsGeoJSON 폴리곤
    assert health.compute()["components"]["db"]["status"] == "ok"


def test_flood_simulation_end_to_end(real_db):
    """모의 호우·침수 → 판정 → 좌표 조회 → 해제 (A3 완료 기준: 임의 좌표 입력 시 침수 위험도 반환)"""
    from risk import queries, simulate
    from app import layers
    res = simulate.apply("heavy_rain_flood")
    assert res["accepted"] and res["risk_run"] == "success" and res["assessments"] >= 8
    p = queries.point_risk(35.99069, 129.556057)                    # 구룡포환승센터
    flood = next(i for i in p["items"] if i["hazard"] == "flood")
    assert flood["level"] == "warning" and "230mm" in flood["reason"]
    assert queries.point_risk(35.93, 129.50)["max_level"] == "normal"   # 구룡포 밖
    ids = {f["id"] for f in queries.areas(None, None, layers.GURYONGPO_BBOX)["features"]}
    simulate.apply("heavy_rain_flood")                                # 같은 판정 → 같은 영역 id 유지
    assert ids == {f["id"] for f in queries.areas(None, None, layers.GURYONGPO_BBOX)["features"]}
    simulate.apply("clear")
    assert queries.point_risk(35.99069, 129.556057)["max_level"] == "normal"


def test_alert_pipeline_end_to_end(real_db):
    """A5 완료 기준: 가상 특보 입력 → 해당 사용자에게 경고 도달 (사용자 등록 → 장소 → 모의 호우·침수 → 폴링)"""
    from fastapi.testclient import TestClient
    from app.main import app
    from risk import simulate
    c = TestClient(app)
    me = {"Authorization": "Bearer dev:a5-near"}
    far = {"Authorization": "Bearer dev:a5-far"}
    try:
        assert c.post("/api/v1/user", headers=me, json={"birth_year": 1950,
                                                         "walking_ability": "limited"}).status_code == 201
        assert c.post("/api/v1/user", headers=far, json={}).status_code == 201
        place = c.post("/api/v1/user/places", headers=me, json={"place_type": "home", "label": "우리집",
                                                                "address": "환승센터"})
        assert place.status_code == 201
        c.post("/api/v1/user/places", headers=far, json={"place_type": "home", "label": "먼 집",
                                                         "address": "구룡포 밖"})
        res = simulate.apply("heavy_rain_flood")
        assert res["alerts_run"] == "success" and res["new_alerts"] >= 1

        d = c.get("/api/v1/alerts", headers=me).json()
        evac = [a for a in d["alerts"] if a["response_required"]]
        flood = next(a for a in evac if a["risk"]["hazard"] == "flood")
        assert flood["risk"]["level"] == "warning" and flood["incident_id"] and flood["reason"]["trigger"] == "place"
        assert "'도움 필요'" in flood["body"] and d["mode"] == "emergency" and d["evacuation"]
        assert len(evac) == 1 and "호우 경보도 함께 발효 중" in flood["body"]       # 침수·호우 대피 확인은 1건으로
        assert c.get("/api/v1/alerts", headers=far).json()["alerts"] == []        # 구룡포 밖

        n = len(d["alerts"])
        simulate.apply("heavy_rain_flood")                                        # 같은 판정 → 중복 경고 없음
        assert len(c.get("/api/v1/alerts", headers=me).json()["alerts"]) == n
        assert c.post(f"/api/v1/alerts/{flood['id']}/read", headers=me).status_code == 204

        simulate.apply("clear")                                                   # 판정 해제 → 대피 상황 종료
        assert real_db.fetch_one("SELECT closed_at FROM care.incidents WHERE id = %(i)s",
                                 {"i": flood["incident_id"]})["closed_at"] is not None
        assert c.get("/api/v1/alerts", headers=me).json()["evacuation"] is None
    finally:
        simulate.apply("clear")
        real_db.execute("DELETE FROM users WHERE firebase_uid IN ('a5-near', 'a5-far')")


def test_evacuation_response_end_to_end(real_db):
    """A12 완료 기준: 가상 경고에 응답하면 DB 와 /dashboard 에 상태가 반영됨 (+ 재알림·이관·방재단 대신 기록·종료)"""
    from datetime import datetime, timedelta, timezone
    from fastapi.testclient import TestClient
    from app.main import app
    from alerts import evacuation
    from risk import simulate
    c = TestClient(app)
    me = {"Authorization": "Bearer dev:a12-me"}
    staff = {"Authorization": "Bearer dev:responder-a12"}
    dash = {"lat": 35.99069, "lng": 129.556057}
    try:
        c.post("/api/v1/user", headers=me, json={})
        c.post("/api/v1/user/places", headers=me, json={"place_type": "home", "label": "우리집",
                                                        "address": "환승센터"})
        simulate.apply("heavy_rain_flood")
        alert = next(a for a in c.get("/api/v1/alerts", headers=me).json()["alerts"] if a["response_required"])
        iid = alert["incident_id"]
        target = real_db.fetch_one("""SELECT t.id FROM care.incident_targets t JOIN users u ON u.id = t.user_id
                                      WHERE u.firebase_uid = 'a12-me' AND t.incident_id = %(i)s""", {"i": iid})["id"]

        # 미응답 3분 → 재알림, 11분 → 이관 (시간을 당겨서)
        real_db.execute("UPDATE care.incident_targets SET created_at = now() - interval '3 minutes' WHERE id = %(t)s", {"t": target})
        evacuation.run_followups()
        assert real_db.fetch_one("SELECT reminder_count FROM care.incident_targets WHERE id = %(t)s", {"t": target})["reminder_count"] == 1
        real_db.execute("UPDATE care.incident_targets SET created_at = now() - interval '11 minutes' WHERE id = %(t)s", {"t": target})
        evacuation.run_followups()
        assert real_db.fetch_one("SELECT escalated_at FROM care.incident_targets WHERE id = %(t)s", {"t": target})["escalated_at"]

        # 응답 → DB · /dashboard · /alerts · 방재단 화면
        r = c.post(f"/api/v1/alerts/{alert['id']}/response", headers=me, json={"status": "evacuating", "via": "button"})
        assert r.status_code == 200 and r.json()["recheck_after_min"] == 10
        assert c.get("/api/v1/dashboard", headers=me, params=dash).json()["evacuation"]["status"] == "evacuating"
        polled = c.get("/api/v1/alerts", headers=me).json()
        assert polled["evacuation"]["status"] == "evacuating"
        assert next(a for a in polled["alerts"] if a["id"] == alert["id"])["my_status"] == "evacuating"
        hist = real_db.fetch_all("SELECT status::text, via::text FROM care.evacuation_responses WHERE target_id = %(t)s", {"t": target})
        assert [(h["status"], h["via"]) for h in hist] == [("evacuating", "button")]
        d = c.get(f"/api/v1/admin/incidents/{iid}", headers=staff).json()
        mine = next(t for t in d["targets"] if t["id"] == str(target))
        assert mine["status"] == "evacuating" and mine["escalated"] and mine["reminder_count"] == 1

        # 대피 중 10분 → 재확인
        real_db.execute("UPDATE care.incident_targets SET status_at = now() - interval '10 minutes', "
                        "last_reminder_at = now() - interval '12 minutes' WHERE id = %(t)s", {"t": target})
        assert evacuation.next_action(real_db.fetch_one(
            "SELECT status::text, created_at, status_at, last_reminder_at, escalated_at, user_id, alert_id "
            "FROM care.incident_targets WHERE id = %(t)s", {"t": target}), datetime.now(timezone.utc)) == "reminder"

        # 방재단이 대신 기록 + 담당 지정 → 종료 → 응답 409
        t = c.patch(f"/api/v1/admin/incidents/{iid}/targets/{target}", headers=staff,
                    json={"status": "evacuated", "assigned_to": "me"}).json()
        assert t["status"] == "evacuated" and t["status_via"] == "responder" and t["assigned_to"]["is_me"]
        assert c.post(f"/api/v1/admin/incidents/{iid}/close", headers=staff).json()["closed_at"]
        r = c.post(f"/api/v1/alerts/{alert['id']}/response", headers=me, json={"status": "evacuated", "via": "button"})
        assert r.status_code == 409
        assert c.get("/api/v1/dashboard", headers=me, params=dash).json()["evacuation"] is None

        # 방재단이 닫은 상황은 같은 판정이 계속돼도 다시 열지 않음
        simulate.apply("heavy_rain_flood")
        assert real_db.fetch_one("SELECT count(*) AS n FROM care.incidents WHERE id <> %(i)s AND closed_at IS NULL "
                                 "AND assessment_id = (SELECT assessment_id FROM care.incidents WHERE id = %(i)s)",
                                 {"i": iid})["n"] == 0

        # 수동 시작 (원 500m) → 영역 안 사용자에게 대피 확인 경고
        r = c.post("/api/v1/admin/incidents", headers=staff, json={
            "hazard": "landslide", "level": "warning", "title": "시험 대피", "message": "구룡포초로 대피하세요",
            "area": {"center": {"lat": 35.99069, "lng": 129.556057}, "radius_m": 500}})
        assert r.status_code == 201
        manual = r.json()["id"]
        a = next(a for a in c.get("/api/v1/alerts", headers=me).json()["alerts"] if a["incident_id"] == manual)
        assert a["response_required"] and a["body"].startswith("방재단 안내: 구룡포초로 대피하세요")
        c.post(f"/api/v1/admin/incidents/{manual}/close", headers=staff)
    finally:
        simulate.apply("clear")
        real_db.execute("DELETE FROM care.incidents WHERE created_by IN (SELECT id FROM users WHERE firebase_uid = 'responder-a12')")
        real_db.execute("DELETE FROM users WHERE firebase_uid IN ('a12-me', 'responder-a12')")


def test_households_end_to_end(real_db):
    """A13 완료 기준: 동의 없이는 민감정보가 저장되지 않고, 일반 계정은 타 가구 정보를 조회할 수 없음"""
    from fastapi.testclient import TestClient
    from app.main import app
    from risk import simulate
    c = TestClient(app)
    me = {"Authorization": "Bearer dev:a13-me"}
    staff = {"Authorization": "Bearer dev:responder-a13"}
    cg = {"Authorization": "Bearer dev:caregiver-a13"}
    try:
        # 건강 정보는 care.user_health 로 (public.user_profiles 에는 컬럼이 없음)
        c.post("/api/v1/user", headers=me, json={"nickname": "하린"})
        c.patch("/api/v1/user", headers=me, json={"blood_type": "A+", "medical_note": "고혈압 약"})
        assert c.get("/api/v1/user", headers=me).json()["profile"]["blood_type"] == "A+"
        assert real_db.fetch_one("""SELECT count(*) AS n FROM information_schema.columns WHERE table_schema = 'public'
                                    AND table_name = 'user_profiles' AND column_name IN ('blood_type', 'medical_note')""")["n"] == 0
        assert real_db.fetch_one("""SELECT h.medical_note FROM care.user_health h JOIN users u ON u.id = h.user_id
                                    WHERE u.firebase_uid = 'a13-me'""")["medical_note"] == "고혈압 약"

        # 본인 등록 — 동의 없으면 422 + 저장 안 됨, 동의하면 버전과 함께 저장
        body = {"location": {"lat": 35.99069, "lng": 129.556057}, "needs": ["elderly", "living_alone"]}
        assert c.put("/api/v1/user/household", headers=me, json=body).status_code == 422
        assert c.get("/api/v1/user/household", headers=me).status_code == 404
        h = c.put("/api/v1/user/household", headers=me, json={**body, "consent": True}).json()
        assert h["label"] == "하린 댁" and h["consent"]["method"] == "app" and h["consent"]["version"] == "v1" and h["has_app"]
        assert c.get("/api/v1/user", headers=me).json()["household"]["id"] == h["id"]

        # 일반 계정은 방재단 API 403, 생활지원사는 담당 가구만
        assert c.get("/api/v1/admin/households", headers=me).status_code == 403
        assert c.get(f"/api/v1/admin/households/{h['id']}", headers=me).status_code == 403
        mine = c.post("/api/v1/admin/households", headers=cg, json={
            "label": "삼정리 이OO 댁", "location": {"lat": 35.979, "lng": 129.56}, "needs": ["vision"],
            "consent_method": "verbal", "consent_by": "보호자 이OO"}).json()
        assert mine["source"] == "caregiver" and mine["caregiver"] and mine["consent"]["method"] == "verbal"
        assert {x["id"] for x in c.get("/api/v1/admin/households", headers=cg).json()} == {mine["id"]}
        assert c.get(f"/api/v1/admin/households/{h['id']}", headers=cg).status_code == 404
        assert {h["id"], mine["id"]} <= {x["id"] for x in c.get("/api/v1/admin/households", headers=staff).json()}

        # 시연 가구 → 모의 침수 → 대피 상황 대상에 가구가 들어감
        res = simulate.apply("demo_households")
        assert res["households"] == len(simulate.DEMO_HOUSEHOLDS) + 1   # + 산사태 비탈 가구
        demo = [x for x in c.get("/api/v1/admin/households", headers=staff, params={"q": "[시연]"}).json()]
        assert len(demo) == len(simulate.DEMO_HOUSEHOLDS) + 1 and any((x["landslide_zone"] or "").startswith("산사태위험지도 1등급") for x in demo)
        simulate.apply("heavy_rain_flood")
        flood = next(i for i in c.get("/api/v1/admin/incidents", headers=staff).json() if i["hazard"] == "flood")
        labels = {t["label"] for t in c.get(f"/api/v1/admin/incidents/{flood['id']}", headers=staff).json()["targets"]}
        assert "[시연] 환승센터 옆 휠체어 어르신 댁" in labels and "하린 댁" in labels

        # 동의 철회 → 삭제 (대피 대상에서도 빠짐)
        assert c.delete("/api/v1/user/household", headers=me).status_code == 204
        assert c.get("/api/v1/user/household", headers=me).status_code == 404
        assert simulate.apply("demo_households_clear")["removed_households"] == len(simulate.DEMO_HOUSEHOLDS) + 1
    finally:
        simulate.apply("clear")
        simulate.apply("demo_households_clear")
        real_db.execute("DELETE FROM care.households WHERE label = '삼정리 이OO 댁'")
        real_db.execute("DELETE FROM care.incidents WHERE source = 'simulated'")
        real_db.execute("DELETE FROM users WHERE firebase_uid IN ('a13-me', 'responder-a13', 'caregiver-a13')")


def test_visits_end_to_end(real_db):
    """A14 완료 기준: 방재단 계정으로 명단 조회 → 방문 기록 → 집계 반영"""
    from fastapi.testclient import TestClient
    from app.main import app
    from risk import simulate
    c = TestClient(app)
    me = {"Authorization": "Bearer dev:a14-me"}
    staff = {"Authorization": "Bearer dev:responder-a14"}
    try:
        c.post("/api/v1/user", headers=me, json={})
        c.post("/api/v1/user/places", headers=me, json={"place_type": "home", "label": "우리집", "address": "환승센터"})
        simulate.apply("demo_households")
        simulate.apply("heavy_rain_flood")
        alert = next(a for a in c.get("/api/v1/alerts", headers=me).json()["alerts"] if a["response_required"])
        c.post(f"/api/v1/alerts/{alert['id']}/response", headers=me,
               json={"status": "need_help", "via": "button", "location": {"lat": 35.9906, "lng": 129.5561}})
        iid = alert["incident_id"]

        d = c.get(f"/api/v1/admin/incidents/{iid}", headers=staff).json()            # 명단 조회
        assert d["targets"][0]["kind"] == "app_user" and d["targets"][0]["status"] == "need_help"   # 도움 요청이 1순위
        assert d["summary"]["unvisited_need_help"] == 1 and d["summary"]["visited"] == 0
        app_t = d["targets"][0]["id"]
        hh_t = next(t["id"] for t in d["targets"] if t["label"] == "[시연] 환승센터 옆 휠체어 어르신 댁")

        # 가구: 부재 → 상태 그대로, 기록만
        v = c.post(f"/api/v1/admin/incidents/{iid}/targets/{hh_t}/visits", headers=staff, json={"result": "not_home"})
        assert v.status_code == 201 and v.json()["status_after"] is None
        # 앱 사용자: 함께 대피 → 대피 완료
        v = c.post(f"/api/v1/admin/incidents/{iid}/targets/{app_t}/visits", headers=staff,
                   json={"result": "evacuated_with_help", "note": "부축해서 대피소 도착"})
        assert v.status_code == 201 and v.json()["household_id"] is None and v.json()["status_after"] == "evacuated"

        d = c.get(f"/api/v1/admin/incidents/{iid}", headers=staff).json()            # 집계 반영
        assert d["summary"]["visited"] == 2 and d["summary"]["unvisited_need_help"] == 0
        tt = {t["id"]: t for t in d["targets"]}
        assert tt[app_t]["status"] == "evacuated" and tt[app_t]["status_via"] == "responder"
        assert tt[app_t]["last_visit"]["note"] == "부축해서 대피소 도착"
        assert tt[hh_t]["status"] == "no_response" and tt[hh_t]["last_visit"]["result"] == "not_home"
        assert c.get("/api/v1/dashboard", headers=me, params={"lat": 35.99, "lng": 129.556}).json()["evacuation"]["status"] == "evacuated"
        hh_id = tt[hh_t]["household_id"]
        assert c.get(f"/api/v1/admin/households/{hh_id}", headers=staff).json()["recent_visits"][0]["result"] == "not_home"
        c.post(f"/api/v1/admin/incidents/{iid}/close", headers=staff)
        assert c.post(f"/api/v1/admin/incidents/{iid}/targets/{hh_t}/visits", headers=staff,
                      json={"result": "transported"}).status_code == 409
    finally:
        simulate.apply("clear")
        simulate.apply("demo_households_clear")
        real_db.execute("DELETE FROM care.incidents WHERE source = 'simulated'")
        real_db.execute("DELETE FROM users WHERE firebase_uid IN ('a14-me', 'responder-a14')")
