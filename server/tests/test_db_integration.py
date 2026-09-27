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
