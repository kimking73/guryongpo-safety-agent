"""DB 조회 tool을 실제 로컬 DB(localhost:5433)에 붙여 확인 (B3). 읽기 전용 계정이 쓰기를 막는지도 본다.

실행: cd 코드/ai && .venv/bin/python -m pytest -m db -q   (docker compose로 db가 떠 있어야 한다)
접속 정보는 루트 .env의 AI_DB_USER·AI_DB_PASSWORD·DB_NAME·DB_HOST_PORT.
"""

import os
from pathlib import Path

import pytest

pytestmark = pytest.mark.db

ROOT_ENV = Path(__file__).resolve().parents[2] / ".env"
for line in (ROOT_ENV.read_text(encoding="utf-8").splitlines() if ROOT_ENV.exists() else []):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip())

import psycopg  # noqa: E402

from guardian_ai import db as D  # noqa: E402
from guardian_ai import tools as T  # noqa: E402

PORT = (35.9905, 129.5560)   # 구룡포항 부근


@pytest.fixture(scope="module")
def fetch():
    database = D.Database()
    try:
        database.fetch_all("SELECT 1")
    except Exception as e:  # noqa: BLE001
        pytest.skip(f"로컬 DB에 접속할 수 없음 ({type(e).__name__}) — docker compose up -d db, 07_ai_readonly.sh 확인")
    yield database.fetch_all
    database.close()


def test_readonly_account_cannot_write():
    with psycopg.connect(D.conninfo(), autocommit=True) as conn:
        assert conn.execute("SELECT current_setting('default_transaction_read_only')").fetchone()[0] == "on"
        with pytest.raises(psycopg.errors.ReadOnlySqlTransaction):
            conn.execute("INSERT INTO data_sources(code) VALUES ('ai-write-test')")
        # 읽기 전용 설정을 스스로 풀어도 SELECT 권한뿐이라 막혀야 한다 (두 겹 방어)
        conn.execute("SET default_transaction_read_only = off")
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute("INSERT INTO data_sources(code) VALUES ('ai-write-test')")


def test_tools_read_real_tables(fetch):
    lat, lon = PORT
    risk = T.get_risk_at(lat, lon, fetch=fetch)
    assert risk["available"] and risk["max_level"] in T.LEVEL_ORDER
    water = T.get_observations("water_level", lat, lon, fetch=fetch)
    assert water["available"] and water["items"], "수위 관측값 없음 — collector가 도는지 확인"
    assert {i["metric"] for i in water["items"]} <= {"flood_depth", "river_level", "manhole_level"}
    assert T.get_weather_warnings(fetch=fetch)["available"]
    assert T.get_disaster_messages(fetch=fetch)["available"]
    zones = T.get_hazard_zones(lat, lon, radius_m=2000, fetch=fetch)
    assert zones["available"] and zones["items"] and zones["items"][0]["hazard"] == "landslide"
    shelters = T.get_facilities("shelter", lat, lon, fetch=fetch)
    assert shelters["available"] and shelters["items"][0]["distance_m"] <= shelters["items"][-1]["distance_m"]
    guides = T.get_action_guides("heavy_rain", "during", "warning", ["resident"], fetch=fetch)
    assert guides["available"] and guides["items"]
    assert all(g["min_level"] in ("normal", "watch", "advisory", "warning") for g in guides["items"])
