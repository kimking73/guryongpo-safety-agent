"""시연 모드 SQL(실시간 표를 CTE로 가림)이 실제 PostgreSQL·PostGIS에서 돌고, tool 결과가 시연 값이 되는지 (db 마커).

실행: cd 코드/ai && .venv/bin/python -m pytest -m db -q tests/test_demo_db_live.py   (로컬 db + AI_DB_* 필요, api 불필요)
"""

import pytest

from guardian_ai import demo as D
from guardian_ai import tools as T

from tests.test_demo import api
from tests.test_tools_db_live import fetch  # noqa: F401 — 로컬 DB fixture

pytestmark = pytest.mark.db

INSIDE = (35.992, 129.552)    # 시연 침수 경보 영역(AREA) 안


@pytest.fixture(autouse=True)
def demo_source(monkeypatch):
    monkeypatch.setattr(D, "_source", api())


def test_risk_and_hazard_checks_use_demo_area(fetch):  # noqa: F811
    with D.active(True):
        risk = T.get_risk_at(*INSIDE, fetch=fetch)
        at = T.hazards_at(*INSIDE, fetch=fetch)
        shelters = T.get_safe_shelters(*INSIDE, fetch=fetch)
    assert risk["available"] and risk["max_level"] == "warning" and risk["data_stale"] is False
    assert risk["items"][0]["label"] == "침수 경보" and risk["items"][0]["simulated"] is True
    assert at["labels"] == "침수 경보"
    assert shelters["available"] and shelters["items"]


def test_observations_warnings_messages_forecast_use_demo_rows(fetch):  # noqa: F811
    with D.active(True):
        rain = T.get_observations("rain", *INSIDE, fetch=fetch)
        uv = T.get_observations("uv", *INSIDE, fetch=fetch)
        warnings = T.get_weather_warnings(fetch=fetch)
        messages = T.get_disaster_messages(hours=24 * 365, fetch=fetch)
        forecast = T.get_forecast(*INSIDE, hours=24 * 365, fetch=fetch)
    assert rain["available"] and [(i["metric"], i["value"]) for i in rain["items"]] == [("rain_1h", 41.5)]
    assert rain["items"][0]["simulated"] is True
    assert [i["value"] for i in uv["items"]] == [7.4]
    assert warnings["items"][0]["headline"] == "[시연] 포항시 호우경보" and warnings["items"][0]["status"] == "active"
    assert messages["items"][0]["text"] == "[시연] 호우경보 발효"
    assert forecast["available"] is False or forecast["periods"]   # 시연 예보 시각이 지나면 비어 있을 수 있다
