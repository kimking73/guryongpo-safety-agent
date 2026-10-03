"""실제 PostgreSQL+PostGIS 에 적재 (TEST_DATABASE_URL 이 있을 때만)

  docker compose exec db sh -c 'createdb -U "$POSTGRES_USER" guardian_test && for f in /docker-entrypoint-initdb.d/*.sql; do psql -q -U "$POSTGRES_USER" -d guardian_test -f $f; done'
  TEST_DATABASE_URL=postgresql://guardian:guardian-local-only@localhost:5433/guardian_test .venv/bin/python -m pytest -q
"""
import os

import pytest

pytestmark = pytest.mark.skipif(not os.environ.get("TEST_DATABASE_URL"), reason="TEST_DATABASE_URL 없음")


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
        assert c.post("/api/v1/user", headers=me, json={"user_type": "resident", "birth_year": 1950,
                                                         "walking_ability": "limited"}).status_code == 201
        assert c.post("/api/v1/user", headers=far, json={}).status_code == 201
        place = c.post("/api/v1/user/places", headers=me, json={"place_type": "home", "label": "우리집",
                                                                "location": {"lat": 35.99069, "lng": 129.556057}})
        assert place.status_code == 201
        c.post("/api/v1/user/places", headers=far, json={"place_type": "home", "label": "먼 집",
                                                         "location": {"lat": 35.93, "lng": 129.50}})
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
